import Foundation

/// A stable 64-bit hash, spelled out here rather than taken from `Hashable`.
///
/// `String.hashValue` is seeded per process, so it is a different number in every
/// launch. Thread ids ARE document keys (`DocumentKeys.thread(_:)`), so a
/// per-launch id would write a brand-new thread document on every relaunch and
/// leave the previous one as an unreachable ghost row in the month index. FNV-1a
/// is used because it is four lines, has no dependency, and — unlike a truncated
/// cryptographic digest — cannot be mistaken for a security primitive by a later
/// reader.
///
/// Collisions are a wrong *merge*, not a crash, so the width matters: 64 bits over
/// the number of `Message-ID`s in one mailbox keeps the probability far below the
/// rate at which servers reuse a `Message-ID` outright, which is the failure this
/// cannot defend against anyway.
enum IMAPStableHash {
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Data(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016lx", hash)
    }
}

/// Where one message physically is: the mailbox, the `UIDVALIDITY` generation the
/// UID was observed in, and the UID.
///
/// This is `MailMessage.id` for every IMAP message, and the choice needs stating
/// because a bare UID is explicitly ruled out (see `IMAPFetchResponse`): a UID is
/// mailbox-local and a `UIDVALIDITY` change voids it. A *composite* locator is not
/// a bare UID and fixes both problems:
///
/// - It carries the mailbox, so `fetchBody`/`fetchAttachment` — which the
///   `MailProvider` protocol hands nothing but a message id — can `SELECT` the
///   right folder with no side index to consult. That statelessness is the whole
///   reason it is not, say, a hash of the `Message-ID`.
/// - It carries the generation, so an id minted before a `UIDVALIDITY` change is
///   *visibly* stale rather than silently pointing at a different message. The
///   provider refuses a locator whose generation no longer matches the server's,
///   which costs a re-fetch and cannot fetch the wrong mail.
///
/// **Thread** ids are deliberately NOT built from this — see `threadID(root:)`.
struct IMAPMessageLocator: Hashable, Sendable {
    let mailbox: String
    let uidValidity: UInt32
    let uid: UInt32

    init(mailbox: String, uidValidity: UInt32, uid: UInt32) {
        self.mailbox = mailbox; self.uidValidity = uidValidity; self.uid = uid
    }

    /// `imap.<uidvalidity>.<uid>.<base64url(mailbox)>`.
    ///
    /// The mailbox is base64url-encoded rather than appended raw because a
    /// mailbox name may legally contain a `.` (it is Dovecot's usual hierarchy
    /// delimiter), which would make the field split ambiguous. base64url's
    /// alphabet excludes `.`, so exactly three separators appear and the decode
    /// below is unambiguous for every name a server can send.
    var encoded: String {
        let name = Data(mailbox.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "imap.\(uidValidity).\(uid).\(name)"
    }

    /// `nil` for anything this build did not mint — a Gmail message id, a
    /// truncated string, a future format. `nil` is a refusal the provider turns
    /// into `MailError.unknownThread`/`decodingFailed`; it never guesses a UID.
    init?(encoded text: String) {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "imap",
              let uidValidity = UInt32(fields[1]), let uid = UInt32(fields[2]),
              let name = Self.decodeName(String(fields[3])) else { return nil }
        self.mailbox = name
        self.uidValidity = uidValidity
        self.uid = uid
    }

    private static func decodeName(_ text: String) -> String? {
        var padded = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Groups fetched messages into `MailThread`s with **stable** ids, and says which
/// previously separate thread identities a group has swallowed.
///
/// Threading itself is `LocalThreading`'s — union-find over
/// `Message-ID`/`References`/`In-Reply-To`, written in M0 for exactly this
/// consumer and not re-implemented here. What this type adds is the two things
/// `LocalThreading` deliberately does not decide: which id a group gets, and what
/// happens to the ids the group used to be.
struct IMAPThreadAssembler: Sendable {
    let accountID: String

    /// One fetched message with the place it was fetched from.
    struct Input: Sendable {
        let locator: IMAPMessageLocator
        let fetched: IMAPFetchResponse
    }

    /// One thread, plus the ids it may be retiring.
    struct Assembled: Sendable {
        let thread: MailThread
        /// Thread ids this group's messages could each have been the root of
        /// before it existed. A **superset**, filtered against the store in
        /// `commit`, and that direction is deliberate: the assembler cannot see
        /// the store, and over-reporting costs a lookup while under-reporting
        /// leaves a ghost row in the month index forever.
        let candidateLosingIDs: [String]
    }

    // MARK: - Identity

    /// A thread's id: `imapt-<hash of the root Message-ID>`.
    ///
    /// Derived from the root `Message-ID` and from nothing else. Not from a UID —
    /// a UID is mailbox-local and `UIDVALIDITY` can void it, so a UID-derived
    /// thread id would change identity for every message in a re-provisioned
    /// folder and orphan every stored thread document. Not from the subject
    /// either: `LocalThreading` documents why subject matching is wrong, and an
    /// id built from it would inherit the same defect.
    static func threadID(root messageKey: String) -> String {
        "imapt-\(IMAPStableHash.hex(messageKey))"
    }

    /// The key a message is threaded by: its `Message-ID`, or a synthetic
    /// stand-in.
    ///
    /// A message with no `Message-ID` is rare but real (some mailing-list
    /// software, some MTAs). It cannot be dropped — that is silently losing mail
    /// — and it cannot be keyed by UID, for the reason `threadID(root:)` gives.
    /// So the stand-in is a hash over the fields that identify the message
    /// independently of where it is stored: the raw `Date:`, the subject and the
    /// first `From` address. Two genuinely identical such messages collapse into
    /// one thread; that is the accepted cost of never keying on a UID.
    static func messageKey(_ fetched: IMAPFetchResponse) -> String {
        if let id = fetched.envelope?.messageID, !id.isEmpty { return id }
        let envelope = fetched.envelope
        let parts = [envelope?.rawDate ?? "", envelope?.subject ?? "",
                     envelope?.from.first?.email ?? ""]
        return "synthetic-\(IMAPStableHash.hex(parts.joined(separator: "\u{1F}")))"
    }

    /// Every `Message-ID` a message points at, from the envelope's `In-Reply-To`
    /// and from the fetched `References` header block.
    ///
    /// Both sources are read because neither alone is sufficient: `ENVELOPE`
    /// carries `In-Reply-To` but never `References`, and the
    /// `BODY[HEADER.FIELDS (…)]` block carries both but is absent from a
    /// FLAGS-only re-scan line.
    static func references(_ fetched: IMAPFetchResponse) -> [String] {
        var result: [String] = []
        if let inReplyTo = fetched.envelope?.inReplyTo, !inReplyTo.isEmpty {
            result.append(inReplyTo)
        }
        if let headers = IMAPFetchParser.headers(fetched) {
            if let inReplyTo = headers.inReplyTo, !result.contains(inReplyTo) {
                result.append(inReplyTo)
            }
            for reference in headers.references where !result.contains(reference) {
                result.append(reference)
            }
        }
        return result
    }

    // MARK: - Assembly

    /// Groups `inputs` into threads. Deterministic for a given set of inputs
    /// regardless of the order they arrive in: inputs are sorted by
    /// `(mailbox, uid)` first, duplicates of one `Message-ID` collapse onto the
    /// lowest-sorting locator, and the root is chosen by a total order.
    func assemble(_ inputs: [Input]) -> [Assembled] {
        let ordered = inputs.sorted {
            ($0.locator.mailbox, $0.locator.uid) < ($1.locator.mailbox, $1.locator.uid)
        }
        // One node per `Message-ID`. The same message present in two mailboxes
        // (INBOX and an archive that Gmail-style servers both list it in) is ONE
        // message, not two, and threading it twice would double every count the
        // inbox shows.
        var byKey: [String: Input] = [:]
        var keysInOrder: [String] = []
        var referencesByKey: [String: [String]] = [:]
        for input in ordered {
            let key = Self.messageKey(input.fetched)
            guard byKey[key] == nil else { continue }
            byKey[key] = input
            keysInOrder.append(key)
            referencesByKey[key] = Self.references(input.fetched)
        }

        let nodes = keysInOrder.map { key in
            LocalThreading.Node(messageID: key,
                                references: referencesByKey[key] ?? [],
                                inReplyTo: nil)
        }
        // Sorted so the returned thread order is stable too — a page of threads
        // that reorders between two identical walks is indistinguishable, to a
        // caller diffing it, from mail having moved.
        let groups = LocalThreading.group(nodes).sorted { ($0.min() ?? "") < ($1.min() ?? "") }

        return groups.compactMap { group in
            guard let root = Self.root(of: group, references: referencesByKey) else { return nil }
            let threadID = Self.threadID(root: root)
            let messages = group.compactMap { key -> MailMessage? in
                guard let input = byKey[key] else { return nil }
                return IMAPFetchParser.message(input.fetched,
                                               id: input.locator.encoded,
                                               threadID: threadID)
            }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            guard !messages.isEmpty else { return nil }
            let losing = group.map(Self.threadID(root:)).filter { $0 != threadID }.sorted()
            return Assembled(
                thread: MailThread(id: threadID, accountID: accountID, messages: messages),
                candidateLosingIDs: losing)
        }
    }

    /// The group's root `Message-ID`: a member that references no other member,
    /// lexicographically least when several qualify.
    ///
    /// The tie-break is not cosmetic. A group can legitimately have two roots —
    /// that is precisely the shape a message linking two previously separate
    /// threads produces — and "whichever came first" would make the surviving id
    /// depend on fetch order, so the same mailbox walked twice would produce two
    /// different ids. A total order over the ids themselves is the only choice
    /// that is stable across runs.
    ///
    /// A reference cycle (two messages citing each other, which malformed clients
    /// do produce) leaves no member unreferenced; the fallback is the least id in
    /// the group, so the thread still gets one stable id rather than none.
    private static func root(of group: [String],
                            references: [String: [String]]) -> String? {
        let members = Set(group)
        let unreferenced = group.filter { key in
            (references[key] ?? []).allSatisfy { !members.contains($0) || $0 == key }
        }
        return (unreferenced.isEmpty ? group : unreferenced).min()
    }

    // MARK: - Committing

    /// Writes assembled threads to the store, merging where a group has swallowed
    /// a thread identity that is actually on disk.
    ///
    /// The filter against `store.thread(_:)` is what keeps the destructive path
    /// off the ordinary sync path: `candidateLosingIDs` is non-empty for every
    /// multi-message thread, but `mergeThreads` — which deletes documents and
    /// sweeps every month shard — is called only when one of those ids really is
    /// a stored thread that this group is retiring. Everything else is an
    /// ordinary `upsertThread`.
    @MainActor
    static func commit(_ assembled: [Assembled], to store: MailStore) throws {
        for entry in assembled {
            let losing = entry.candidateLosingIDs.filter { store.thread($0) != nil }
            if losing.isEmpty {
                try store.upsertThread(entry.thread)
            } else {
                try store.mergeThreads(losingIDs: losing, into: entry.thread)
            }
        }
    }
}
