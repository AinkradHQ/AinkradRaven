import Foundation

/// IMAP4rev1 behind the unchanged `MailProvider` protocol.
///
/// ## What is different from Gmail, and where the work went
///
/// Gmail's provider *maps*: threads, labels and search are server-side, so each
/// protocol method is close to one HTTP request. IMAP has none of the three, so
/// this file orchestrates rather than maps — `LocalThreading` via
/// `IMAPThreadAssembler` for threads, `IMAPVocabulary` over the `LIST`ed directory
/// for labels, `UID SEARCH` for search — and it keeps an `IMAPMessageIndex`,
/// because a locally computed thread id maps back to UIDs nowhere on the server.
///
/// ## Known divergences from `GmailProvider`, both deliberate
///
/// 1. **A forwarded message's inner text is not offered as a body.** Task 10's
///    `IMAPBodyPart` leaves a `message/rfc822` part opaque and does not decompose
///    its nested `ENVELOPE`/`BODY`, so a forward whose only text lives inside the
///    attached message reads as an attachment with no body text, where Gmail —
///    which decomposes the nested part server-side — shows the inner text.
///    Deferred, not blocked, and the reason is scope rather than risk: the change
///    belongs in the body-structure layer (`IMAPBodyPart.parse` would decompose the
///    nested `ENVELOPE`/`BODY` at indices 7/8), it needs its own fixtures for the
///    nesting shapes, and nothing has asked for forwarded-message inner text yet.
///    An earlier version of this comment claimed the fix would invalidate stored
///    `MailAttachment.attachmentID`s; that was **wrong** and is recorded here so the
///    correction is not lost. Numbering is prefix-hierarchical
///    (`IMAPBodyPart.numbered(prefix:)`), so decomposing part `2` adds `2.1`/`2.2`
///    and leaves `2` and every sibling's number untouched — and RFC 3501 addresses
///    the inner text as `2.TEXT`, needing no renumbering at all. A wrong reason is
///    how a cheap fix stays deferred forever. The forwarded message is still offered,
///    and still fetchable, as an attachment.
/// 2. **`hasAttachments` on unnamed parts is FIXED, not documented** — see
///    `IMAPBodyPart.carriesAttachment`. Gmail answers true for any non-`text/`,
///    non-`multipart/` part whether or not it has a filename; IMAP answered
///    `!attachments.isEmpty`, which requires one, so the same message showed a
///    paperclip in one account and not in the other. That was cheap to correct in
///    one place and had no id-stability cost.
final class IMAPProvider: MailProvider, @unchecked Sendable {
    let accountID: String
    /// IMAP mutates flags and moves messages; SMTP (Task 15) transmits. `.readWrite`
    /// covers both halves of the protocol's contract, and `send` names the missing
    /// half explicitly rather than pretending to be read-only.
    let capabilities: MailProviderCapabilities = .readWrite

    /// Borrows a ready session for one operation. Called per operation rather than
    /// held, so **caching and reconnection are the closure's business**: a provider
    /// that cached a session itself would have to re-implement "is this socket still
    /// alive", which is what the closure's owner (`ProviderFactory`, or a test's
    /// scripted transport) is already positioned to know.
    ///
    /// Not `private`: Swift's `private` is file-scoped and the write path lives in
    /// `IMAPProvider+Mutations.swift`. Still module-internal. Nothing outside
    /// `withSession` may call it — that is what pairs every acquire with a release.
    let acquire: @Sendable () async throws -> IMAPSessionLease

    /// Transmits one message over SMTP, or `nil` when this account has no
    /// submission server configured.
    ///
    /// A closure, not an `SMTPSubmitter`, because a submitter holds an
    /// `IMAPCredential`. `ProviderFactory` builds it — that file is where the
    /// credential path lives — and this type therefore cannot reach the password
    /// even to log it. `nil` is a real state (a pre-Task-16 settings document has
    /// no `smtp` block) and `send` refuses on it by name.
    ///
    /// Not `private`: `send` lives in `IMAPProvider+Mutations.swift` and Swift's
    /// `private` is file-scoped.
    let submit: (@Sendable (OutgoingMessage) async throws -> String)?

    /// UIDs fetched per `fetchThreads` page.
    private let pageSize: Int

    let index = IMAPMessageIndex()

    /// Where a thread's locators come from when the in-memory `index` has never
    /// seen it — which is every thread, on every launch.
    ///
    /// `IMAPMessageIndex` is process-local and is populated only by a walk. A
    /// relaunch therefore starts with it empty, and a *delta* sync refills it only
    /// for threads that changed, so an older thread's locators never come back
    /// without a full backfill. `applyLabels` used to read the empty index, find
    /// nothing to do, and **return success** — the UI had already applied the
    /// change optimistically, so an archive vanished locally and never reached the
    /// server. That is the silent-no-op failure `destination`'s throw was written
    /// to prevent, arriving one step earlier through a door nobody had shut.
    ///
    /// The recovery needs no new persistence, because the store already holds the
    /// answer: `MailMessage.id` for every IMAP message IS
    /// `IMAPMessageLocator.encoded`, so a stored thread can be decoded straight
    /// back into locators. `ProviderFactory` supplies the reader; the default is
    /// deliberately empty so a test that wants "this provider has never seen that
    /// thread" still gets it.
    let storedLocators: @Sendable (String) async -> [IMAPMessageLocator]

    init(accountID: String, pageSize: Int = 50,
         submit: (@Sendable (OutgoingMessage) async throws -> String)? = nil,
         storedLocators: @escaping @Sendable (String) async -> [IMAPMessageLocator] = { _ in [] },
         acquire: @escaping @Sendable () async throws -> IMAPSessionLease) {
        self.accountID = accountID
        self.pageSize = pageSize
        self.submit = submit
        self.storedLocators = storedLocators
        self.acquire = acquire
    }

    private var assembler: IMAPThreadAssembler { IMAPThreadAssembler(accountID: accountID) }

    // MARK: - Mailbox selection

    /// What a `SELECT` reported. A local, minimal echo of
    /// `IMAPDeltaStrategy.IMAPSelectedMailbox`: this file needs only the three
    /// numbers, and reaching into the delta strategy's private `select` would
    /// couple the provider to the walk's internals for no gain.
    struct Selection: Sendable, Equatable {
        let uidValidity: UInt32
        let uidNext: UInt32?
        let highestModSeq: UInt64?
    }

    @discardableResult
    func select(_ mailbox: String, on session: IMAPSession) async throws -> Selection {
        let response = try await session.execute(
            IMAPCommand("SELECT", [.text(mailbox)], isExclusive: true))
        func code(_ name: String) -> UInt64? {
            for line in response.untagged {
                if let value = IMAPDeltaStrategy.numericResponseCode(name, in: line.tokens) {
                    return value
                }
            }
            return IMAPDeltaStrategy.numericResponseCode(name, in: response.tokens)
        }
        guard let uidValidity = code("UIDVALIDITY").flatMap({ UInt32(exactly: $0) }) else {
            // Same refusal as the delta walk's: a position with no generation
            // cannot be trusted, and defaulting it would let a UID be reused
            // across a re-provisioning.
            throw IMAPDeltaError.missingUIDValidity(mailbox)
        }
        return Selection(uidValidity: uidValidity,
                         uidNext: code("UIDNEXT").flatMap { UInt32(exactly: $0) },
                         highestModSeq: code("HIGHESTMODSEQ"))
    }

    /// The mailboxes a walk covers, in a deterministic order with `INBOX` first.
    ///
    /// `\Noselect` containers are excluded because they cannot be `SELECT`ed at
    /// all. So is `\All` — Gmail's "All Mail" — and that exclusion needs its own
    /// justification, because it is the only place this build declines to read
    /// mail a server offered.
    ///
    /// `\All` is not a folder. RFC 6154 defines it as a *view* containing every
    /// message in the account regardless of where it actually lives, so walking it
    /// re-fetches the entire mailbox a second time: a real account with 281
    /// messages reported over 600 synced, which is the symptom that found this.
    /// The cost is not only the doubled fetch. The walk pages one mailbox at a
    /// time, so `INBOX` and `All Mail` produce the SAME thread id from two
    /// separate `assemble` calls, and the second `upsertThread` replaces the
    /// first — labelling an inbox thread `All Mail`, i.e. archived, and hiding it
    /// from the list it belongs in.
    ///
    /// The deliberate consequence: a message that exists ONLY in `\All` — archived,
    /// carrying no other label — is not synced. That is not a gap being introduced
    /// here, it is the contract `RavenRuntime.searchArchive` already states: mail
    /// outside the synced window is reached by an explicit "search all mail" act
    /// and presented as its own result list, never blended into a view whose whole
    /// promise is "the last 90 days".
    ///
    /// `\Archive` is NOT excluded — a real archive folder holds messages that are
    /// nowhere else, which is exactly the opposite of `\All`. The two share a
    /// canonical `.archive` flag, so the test is on the server's own attribute.
    static func walkable(_ directory: IMAPMailboxDirectory) -> [IMAPMailbox] {
        directory.mailboxes.filter { $0.isSelectable && !$0.isEverythingView }
            .sorted { left, right in
            let leftInbox = left.flag == .inbox, rightInbox = right.flag == .inbox
            if leftInbox != rightInbox { return leftInbox }
            return left.name < right.name
        }
    }

    // MARK: - Fetching

    /// `UID SEARCH …` → the UIDs it named, descending (newest first).
    func searchUIDs(_ arguments: [IMAPCommand.Argument],
                    on session: IMAPSession) async throws -> [UInt32] {
        let response = try await session.execute(
            IMAPCommand("UID SEARCH", arguments, isExclusive: true))
        var uids: [UInt32] = []
        for line in response.untagged
        where line.tokens.first?.stringValue?.uppercased() == "SEARCH" {
            for token in line.tokens.dropFirst() {
                if case .number(let value) = token, let uid = UInt32(exactly: value) {
                    uids.append(uid)
                }
            }
        }
        return uids.sorted(by: >)
    }

    /// `UID FETCH <uids> (…full items)` for one already-`SELECT`ed mailbox, shaped
    /// into assembler inputs.
    ///
    /// Item list shared with `IMAPDeltaStrategy.fullItems` on purpose: an arrival
    /// found by a delta and the same message found by a backfill must be described
    /// by identical bytes, or the two paths thread it differently.
    func fetchMessages(uids: [UInt32], mailbox: String, uidValidity: UInt32,
                       on session: IMAPSession) async throws
        -> [IMAPThreadAssembler.Input] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let response = try await session.execute(IMAPCommand(
            "UID FETCH", [.atom(set), IMAPDeltaStrategy.fullItems], isExclusive: true))
        return try IMAPDeltaStrategy.fetches(in: response.untagged)
            .compactMap { fetched -> IMAPThreadAssembler.Input? in
            guard let uid = IMAPDeltaStrategy.uid(of: fetched) else { return nil }
            return IMAPThreadAssembler.Input(
                locator: IMAPMessageLocator(mailbox: mailbox, uidValidity: uidValidity,
                                            uid: uid),
                fetched: fetched)
        }
    }

    /// Assembles, records and returns. The three always happen together: a thread
    /// handed to a caller whose UIDs were not recorded is a thread `fetchThread`
    /// and `applyLabels` cannot find again.
    func commit(_ inputs: [IMAPThreadAssembler.Input]) async -> [MailThread] {
        let assembled = assembler.assemble(inputs)
        await index.record(assembled, inputs: inputs)
        return assembled.map(\.thread)
    }

    /// Assembled threads *and* the merge information, for a caller that writes to
    /// the store. `IMAPThreadAssembler.commit(_:to:)` is what turns the second half
    /// into a `MailStore.mergeThreads` call.
    func assembleForStore(_ inputs: [IMAPThreadAssembler.Input]) async
        -> [IMAPThreadAssembler.Assembled] {
        let assembled = assembler.assemble(inputs)
        await index.record(assembled, inputs: inputs)
        return assembled
    }

    // MARK: - MailProvider: reads

    /// A page of the backfill walk, one mailbox at a time.
    ///
    /// The page token is `<mailbox index>:<uid ceiling>` and is deliberately
    /// *stateless*: the walk position is entirely in the token, so a backfill
    /// interrupted between pages resumes from the token alone rather than from
    /// anything this object remembers. The ceiling walks DOWN from the newest UID,
    /// which is what makes the page boundary stable while mail is still arriving —
    /// an offset into a `UID SEARCH` result would shift under every arrival and
    /// silently skip a thread.
    func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
      try await withSession { working in
        let boxes = Self.walkable(working.directory)
        var (start, ceiling) = Self.decodePageToken(pageToken)
        while start < boxes.count {
            let mailbox = boxes[start]
            let selection = try await select(mailbox.name, on: working.session)
            var uids = try await searchUIDs(
                [.atom("SINCE"), .atom(Self.imapDate(since))], on: working.session)
            if let ceiling { uids = uids.filter { $0 <= ceiling } }
            guard !uids.isEmpty else {
                start += 1
                ceiling = nil
                continue
            }
            let page = Array(uids.prefix(pageSize))
            let inputs = try await fetchMessages(uids: page, mailbox: mailbox.name,
                                                 uidValidity: selection.uidValidity,
                                                 on: working.session)
            let threads = await commit(inputs)
            let next: String?
            if uids.count > page.count, let last = page.last, last > 1 {
                next = "\(start):\(last - 1)"
            } else if start + 1 < boxes.count {
                next = "\(start + 1):"
            } else {
                next = nil
            }
            return ThreadPage(threads: threads, nextPageToken: next)
        }
        return ThreadPage(threads: [], nextPageToken: nil)
      }
    }

    static func decodePageToken(_ token: String?) -> (start: Int, ceiling: UInt32?) {
        guard let token else { return (0, nil) }
        let fields = token.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let start = Int(fields[0]) else { return (0, nil) }
        return (start, UInt32(fields[1]))
    }

    /// `UID SEARCH SINCE` takes RFC 3501 §9 `date-text`, which is NOT the
    /// `INTERNALDATE` form and NOT RFC 2822 — `1-Jan-2026`, always in the POSIX
    /// locale so a French system does not send `1-janv.-2026`.
    static func imapDate(_ date: Date) -> String { imapDateFormatter.string(from: date) }

    private static let imapDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter
    }()

    func fetchThread(id: String) async throws -> MailThread {
        // Same index-then-store order as `applyLabels`, and for the same reason:
        // the index is empty on every launch, so without the fallback a refresh of
        // an already-stored thread reports `unknownThread` until a full walk.
        var locators = await index.locators(threadID: id)
        if locators.isEmpty { locators = await storedLocators(id) }
        guard !locators.isEmpty else { throw MailError.unknownThread(id) }
        return try await withSession { working in
        var inputs: [IMAPThreadAssembler.Input] = []
        for (mailbox, group) in Dictionary(grouping: locators, by: \.mailbox)
            .sorted(by: { $0.key < $1.key }) {
            let selection = try await select(mailbox, on: working.session)
            // A generation change voids every UID below it, so a stale locator is
            // refused rather than fetched. Refetching from scratch costs a
            // backfill; fetching UID 12 of a re-provisioned mailbox returns
            // somebody else's message.
            guard group.allSatisfy({ $0.uidValidity == selection.uidValidity }) else {
                await index.forget(mailbox: mailbox)
                throw MailError.unknownThread(id)
            }
            inputs += try await fetchMessages(uids: group.map(\.uid), mailbox: mailbox,
                                              uidValidity: selection.uidValidity,
                                              on: working.session)
        }
        let threads = await commit(inputs)
        guard let thread = threads.first(where: { $0.id == id }) else {
            throw MailError.unknownThread(id)
        }
        return thread
        }
    }

    func fetchDelta(cursor: String) async throws -> MailDelta {
      try await withSession { working in
        var position = IMAPSyncCursor(encoded: cursor)
        var changed: Set<String> = []
        var removed: Set<String> = []
        let collector = IMAPArrivalCollector()

        for mailbox in Self.walkable(working.directory) {
            let identity = await index.identity(for: mailbox.name)
            let strategy = IMAPDeltaStrategy(
                session: working.session,
                identity: collector.wrapping(identity))
            let delta = try await strategy.delta(cursor: &position)
            changed.formUnion(delta.changedThreadIDs)
            removed.formUnion(delta.removedThreadIDs)
        }

        // Arrivals are filed AFTER the walk, and in two different ways, because
        // "which thread is this?" has two different answers:
        //
        // - The walk already resolved it (the message cites a thread we hold). The
        //   arrival is ATTACHED to that thread, not re-threaded: re-threading a lone
        //   arrival would put it in a thread of its own, and the index would then
        //   disagree with the id the delta just reported — `fetchThread` on the
        //   reported id would come back without the new message.
        // - The walk had no answer (a brand-new thread). Those are assembled as a
        //   batch, and the changed ids are then remapped, because two messages of
        //   one new thread arriving in the same pass each get a *provisional* id
        //   from the walk. Without the remap the delta would name an id
        //   `fetchThread` can never resolve and the sync engine would retry it
        //   forever.
        var remapped = changed
        for (mailbox, arrivals) in collector.drain() {
            guard let uidValidity = position.mailboxes[mailbox]?.uidValidity else { continue }
            var unthreaded: [IMAPThreadAssembler.Input] = []
            for arrival in arrivals {
                let locator = IMAPMessageLocator(mailbox: mailbox, uidValidity: uidValidity,
                                                 uid: arrival.uid)
                if let known = arrival.knownThreadID {
                    await index.attach(locator, fetched: arrival.fetched, to: known)
                } else {
                    unthreaded.append(IMAPThreadAssembler.Input(locator: locator,
                                                               fetched: arrival.fetched))
                }
            }
            guard !unthreaded.isEmpty else { continue }
            let assembled = await assembleForStore(unthreaded)
            var finalByProvisional: [String: String] = [:]
            for entry in assembled {
                for message in entry.thread.messages {
                    guard let locator = IMAPMessageLocator(encoded: message.id),
                          let arrival = unthreaded.first(where: { $0.locator == locator })
                    else { continue }
                    let provisional = IMAPThreadAssembler.threadID(
                        root: IMAPThreadAssembler.messageKey(arrival.fetched))
                    finalByProvisional[provisional] = entry.thread.id
                }
            }
            remapped = Set(remapped.map { finalByProvisional[$0] ?? $0 })
        }

        // Removal wins over change for one id — `changed.subtracting(removed)`, the
        // rule Task 12 states — so the index is made to agree with what was
        // reported. The cost is stated rather than hidden: a thread that lost one
        // message and gained another IN THE SAME PASS is reported removed, and the
        // arrival is not re-delivered until the next full walk. That is inherent to
        // resolving the collision in the delta rather than in the store, and
        // `IMAPProviderTests` pins the behaviour so a future change to it is
        // deliberate.
        await index.forget(threadIDs: Array(removed))
        // The subtraction here is a SECOND, cross-mailbox guard, not a copy of the
        // strategy's. `IMAPDeltaStrategy` already subtracts within one mailbox
        // (`IMAPProviderTests.strategySubtractsRemovedFromChanged` falsifies that
        // one directly); this one covers a thread whose message in INBOX was expunged
        // while its message in another folder changed, which only appears once the
        // per-mailbox results are unioned and which the strategy therefore cannot see.
        // `IMAPProviderTests.removalWinsAcrossMailboxes` falsifies it, with the same
        // `Message-ID` filed at INBOX UID 10 and `Folder B` UID 30 — one thread, two
        // folders. Removing this line fails that test and nothing else.
        return MailDelta(changedThreadIDs: remapped.subtracting(removed).sorted(),
                         removedThreadIDs: removed.sorted(),
                         newCursor: position.encoded())
      }
    }

    func currentCursor() async throws -> String {
      try await withSession { working in
        var position = IMAPSyncCursor()
        for mailbox in Self.walkable(working.directory) {
            let selection = try await select(mailbox.name, on: working.session)
            position.advance(mailbox: mailbox.name, uidValidity: selection.uidValidity,
                             uidNext: selection.uidNext ?? 1,
                             highestModSeq: selection.highestModSeq)
        }
        return position.encoded()
      }
    }

    /// The account's mailboxes as labels. `id` is the mailbox name because that is
    /// the string a mutation must round-trip back to the server; `kind` is
    /// `.system` only for a mailbox with a canonical meaning, so a user's own
    /// folder is never presented as one of the server's.
    func fetchLabels() async throws -> [MailLabel] {
      try await withSession { working in
        working.directory.mailboxes.map { mailbox in
            let isSystem: Bool
            if case .user = mailbox.flag { isSystem = false } else { isSystem = true }
            return MailLabel(id: mailbox.name, name: mailbox.name,
                             kind: isSystem ? .system : .user)
        }
      }
    }
}
