import Foundation

/// Why a delta pass could not be completed.
///
/// Every case is a *failure*, never a degraded result, and that is the point:
/// `IMAPDeltaStrategy.delta` only writes the caller's cursor on its last line, so
/// throwing any of these holds the cursor and the next pass retries against the
/// same position. A "best effort" delta would advance past changes it never saw,
/// and cursor-based deltas are not re-delivered.
enum IMAPDeltaError: Error, Equatable {
    /// The account has no mailbox carrying this canonical flag.
    ///
    /// Refusing, because `IMAPMailboxDirectory.mailbox(for:)` returns `nil`
    /// rather than a guess and this layer must not undo that: `SELECT "Archive"`
    /// against a server that has no archive is not a cheap mistake — the same
    /// guessed name reaches `UID MOVE` in Task 13.
    case mailboxNotFound(MailFlag)
    /// `SELECT` completed without a `[UIDVALIDITY n]`. A position with no
    /// generation cannot be trusted, so this is fatal to the pass rather than
    /// defaulted.
    case missingUIDValidity(String)
    /// A `uid-set` naming `*`, or otherwise unreadable. See `IMAPSequenceSet`.
    case unresolvableSequenceSet(String)
    case sequenceSetTooWide(String)
}

/// How a fetched message, or a bare UID, becomes a thread id.
///
/// Injected rather than computed here, and the split is deliberate: thread
/// identity is Task 13's (`IMAPThreadAssembler`, ids hashed from the root
/// `Message-ID` via `LocalThreading`), and a UID → thread id lookup is the local
/// store's. This file's whole subject is *which* UIDs changed, which is
/// answerable with neither.
///
/// It is also what makes the CONDSTORE-vs-fallback equality test meaningful: both
/// paths are handed the identical resolver, so any difference in the delta is a
/// difference in the walk and nothing else.
struct IMAPDeltaIdentity: Sendable {
    /// The mailbox every closure below answers for, and the mailbox the pass will
    /// walk — `IMAPDeltaStrategy.delta(cursor:)` reads it from here rather than
    /// taking it as a separate argument.
    ///
    /// It lives in the identity, not in the call, because pairing one mailbox's
    /// UID table with another mailbox's walk is the one mistake this file cannot
    /// survive: `insertSetDifferenceRemovals` treats "known, in range, absent from
    /// the re-scan" as proof of deletion, so an account-wide (or simply
    /// mismatched) `knownUIDs` makes `Folder A`'s re-scan report every message of
    /// `Folder B` as removed. That is silent mail loss with no error anywhere, and
    /// making it unexpressible is worth one field. `IMAPMessageIndex.identity(for:)`
    /// is the only production construction site and snapshots exactly this
    /// mailbox.
    let mailbox: String

    /// Every UID this client already holds for the mailbox. The fallback's
    /// removal detection is exactly "known, in range, and absent from the
    /// re-scan".
    var knownUIDs: @Sendable () -> Set<UInt32>
    /// The flags last stored for a UID, or `nil` for one never seen. `nil` reads
    /// as "changed" — a UID inside the re-scan range that we hold no flags for is
    /// evidence of an earlier partial pass, not of an unchanged message.
    var knownFlags: @Sendable (UInt32) -> Set<MailFlag>?
    /// The thread a held UID belongs to. `nil` for a UID this client never
    /// stored, which is why a removal for an unknown UID contributes nothing.
    var threadID: @Sendable (UInt32) -> String?
    /// The thread a freshly fetched message belongs to — the arrival path, where
    /// there is no stored UID to look up. `nil` when the fetch carried no
    /// envelope (a FLAGS-only re-scan line), and the UID lookup covers that case.
    var threadIDForFetched: @Sendable (IMAPFetchResponse) -> String?
    /// UID for a message *sequence* number, which is all an untagged `EXPUNGE`
    /// carries. `nil` when the sequence map is unknown.
    var uidForSequenceNumber: @Sendable (UInt64) -> UInt32?
}

/// What `SELECT` said about a mailbox, plus the untagged lines it carried.
struct IMAPSelectedMailbox: Sendable, Equatable {
    let uidValidity: UInt32
    /// `nil` when the server published no `[UIDNEXT n]`. Distinct from `1`: a
    /// missing UIDNEXT must leave the stored position alone (costing a re-read of
    /// the tail next pass), whereas `1` would claim the mailbox is empty.
    let uidNext: UInt32?
    /// `nil` when the server reported none — never `0`, for the reason
    /// `IMAPMailboxSyncState.highestModSeq` documents.
    let highestModSeq: UInt64?
    let exists: UInt64?
    let untagged: [IMAPUntaggedResponse]
}

/// One mailbox's delta, by the cheapest walk the server will support.
///
/// ## Three capability shapes, one result
///
/// The matrix has three live cases and each is walked differently:
///
/// - `CONDSTORE` **and** `QRESYNC`: the server does all of it. `SELECT …
///   (QRESYNC …)` reports what vanished, `UID FETCH … (CHANGEDSINCE n)` reports
///   what changed.
/// - `CONDSTORE` **without** `QRESYNC`: `CHANGEDSINCE` still reports changes, but
///   no `VANISHED` can arrive — `QRESYNC` may only be sent when advertised — so
///   removals come from the fallback's bounded set difference. Skipping that step
///   here is silent, permanent deletion loss, because the cursor advances anyway.
/// - Neither: the client reconstructs both, from an arrival walk plus a flag
///   re-scan plus a set difference.
///
/// The three walks are completely different; the `MailDelta` they produce must not
/// be, and `IMAPDeltaStrategyTests` asserts that equality across all three
/// directly, against one scripted mailbox holding a flag change on an old message,
/// an unchanged old message, an arrival and a removal at once.
///
/// ## Attribution
///
/// Untagged `FETCH`/`VANISHED`/`EXPUNGE` data carries no tag, so every command
/// here is `IMAPCommand.isExclusive` and every reader takes
/// `IMAPTaggedResponse.untagged` — the set `IMAPSession` could attribute
/// unambiguously — never the global `untaggedResponses` stream. That is the
/// mechanism `IMAPFetchParser` documents, and it is sufficient *because this file
/// serialises*: it runs one command at a time and never holds one open. No
/// mailbox-scoped router is needed or built here.
struct IMAPDeltaStrategy: Sendable {
    let session: IMAPSession
    let identity: IMAPDeltaIdentity

    /// How many UIDs below the last known position a flag re-scan may cover in
    /// one pass.
    ///
    /// TWO paths depend on this, not one. The no-`CONDSTORE` fallback uses the
    /// re-scan to find both flag changes and removals. A server advertising
    /// `CONDSTORE` *without* `QRESYNC` also runs it, for the set difference
    /// alone: no `VANISHED` can arrive there, so it is the only way a message
    /// deleted between sessions is ever noticed. That path therefore inherits
    /// this bound — a between-sessions deletion older than `flagRescanWindow`
    /// UIDs is still missed on such a server. Strictly better than missing it
    /// always, which is what happened before the set difference was added, and
    /// `QRESYNC` remains the only complete answer.
    ///
    /// **This is what bounds the re-scan**, together with two other properties:
    /// the re-scan asks for `(UID FLAGS)` only — never a body, an envelope or a
    /// structure, so the response is a few tokens per message — and it is exactly
    /// one command per pass, anchored at the top of the mailbox and walking
    /// *down*. An unbounded `UID FETCH 1:* (FLAGS)` on a 200k-message mailbox is
    /// the thing this avoids: it would be issued on every timer tick.
    ///
    /// The cost of the bound is stated plainly rather than hidden: a flag change
    /// on a message older than `flagRescanWindow` UIDs is **not** seen by the
    /// fallback. That is a real limitation of a server with no `CONDSTORE`, and
    /// the honest alternative — re-reading every message's flags forever — is not
    /// one a mail client can afford. It is not a divergence from the CONDSTORE
    /// path within the window, which is what the equality test pins.
    let flagRescanWindow: UInt32

    init(session: IMAPSession, identity: IMAPDeltaIdentity,
         flagRescanWindow: UInt32 = 5_000) {
        self.session = session
        self.identity = identity
        self.flagRescanWindow = flagRescanWindow
    }

    /// The mailbox name for a canonical flag, or a refusal.
    ///
    /// A thin pass-through on purpose: it exists so the refusal has one spelling
    /// and `nil` cannot be quietly turned into `"Archive"` at a call site.
    static func mailboxName(for flag: MailFlag,
                            in directory: IMAPMailboxDirectory) throws -> String {
        guard let mailbox = directory.mailbox(for: flag) else {
            throw IMAPDeltaError.mailboxNotFound(flag)
        }
        return mailbox.name
    }

    // MARK: - The pass

    /// Walks `identity.mailbox` and returns what changed since `cursor`.
    ///
    /// The mailbox is **not** a parameter: it is read from `identity`, so the UID
    /// table the removal detection trusts and the mailbox being walked cannot
    /// disagree. See `IMAPDeltaIdentity.mailbox`.
    ///
    /// `cursor` is `inout` and is assigned **once, on the last line**. That is
    /// the whole of the hold-vs-advance mechanism: a transient failure anywhere
    /// above throws, the caller's cursor is untouched, and the next pass asks the
    /// same question again. There is no separate "partial" flag to get wrong —
    /// `IMAPSyncCursor.advance` is simply never reached.
    ///
    /// A `UIDVALIDITY` change is the one condition that re-walks, and it does so
    /// through `IMAPSyncCursor.reconcile`, which resets this mailbox's position
    /// and no other's.
    func delta(cursor: inout IMAPSyncCursor) async throws -> MailDelta {
        let mailbox = identity.mailbox
        var working = cursor
        let stored = working.mailboxes[mailbox]
        let capabilities = try await session.capabilities()
        let hasCondstore = capabilities.contains("CONDSTORE")
        let hasQresync = capabilities.contains("QRESYNC")

        let selected = try await select(
            mailbox: mailbox,
            resumeFrom: hasQresync && hasCondstore ? stored : nil)
        let decision = working.reconcile(mailbox: mailbox, uidValidity: selected.uidValidity)
        let resume: IMAPMailboxSyncState? = {
            if case .resume(let state) = decision { return state }
            return nil
        }()

        var changed: Set<String> = []
        var removed: Set<String> = []
        // `VANISHED (EARLIER)` rides on the QRESYNC `SELECT`; an untagged
        // `EXPUNGE` can ride on any command. Both are read the same way.
        try collectRemovals(from: selected.untagged, into: &removed)

        if hasCondstore, let since = resume?.highestModSeq {
            try await walkChangedSince(since, resume: resume, selected: selected,
                                       hasQresync: hasQresync,
                                       changed: &changed, removed: &removed)
        } else {
            try await walkWithoutCondstore(resume: resume, selected: selected,
                                           changed: &changed, removed: &removed)
        }

        // `advance` is monotonic, so a `nil` UIDNEXT floors to 1 and leaves the
        // position exactly where it was rather than rewinding it.
        working.advance(mailbox: mailbox, uidValidity: selected.uidValidity,
                        uidNext: selected.uidNext ?? 1,
                        highestModSeq: selected.highestModSeq)
        // The single write. Everything above may throw; nothing above mutates
        // the caller's cursor.
        cursor = working
        return MailDelta(changedThreadIDs: changed.subtracting(removed).sorted(),
                         removedThreadIDs: removed.sorted(),
                         newCursor: working.encoded())
    }

    // MARK: - SELECT

    private func select(mailbox: String,
                        resumeFrom stored: IMAPMailboxSyncState?) async throws
        -> IMAPSelectedMailbox {
        var arguments: [IMAPCommand.Argument] = [.text(mailbox)]
        if let stored, let modSeq = stored.highestModSeq {
            // RFC 7162 §3.2. The pair is (UIDVALIDITY, MODSEQ) and sending a
            // modseq from a *different* generation would ask the server to
            // resynchronise against UIDs that no longer mean anything, so the
            // stored uidValidity travels with it rather than the live one.
            arguments.append(.list([
                .atom("QRESYNC"),
                .list([.atom(String(stored.uidValidity)), .atom(String(modSeq))]),
            ]))
        }
        let response = try await session.execute(
            IMAPCommand("SELECT", arguments, isExclusive: true))
        let lines = response.untagged
        guard let uidValidity = Self.numericResponseCode("UIDVALIDITY", in: lines, or: response)
            .flatMap({ UInt32(exactly: $0) }) else {
            throw IMAPDeltaError.missingUIDValidity(mailbox)
        }
        return IMAPSelectedMailbox(
            uidValidity: uidValidity,
            uidNext: Self.numericResponseCode("UIDNEXT", in: lines, or: response)
                .flatMap { UInt32(exactly: $0) },
            highestModSeq: Self.numericResponseCode("HIGHESTMODSEQ", in: lines, or: response),
            exists: lines.compactMap(Self.existsCount).last,
            untagged: lines)
    }

    private static func existsCount(_ line: IMAPUntaggedResponse) -> UInt64? {
        guard case .number(let count)? = line.tokens.first,
              line.tokens.dropFirst().first?.stringValue?.uppercased() == "EXISTS"
        else { return nil }
        return count
    }

    /// The first `[NAME n]` response code found on any untagged line, falling
    /// back to the tagged completion — servers legitimately publish these in
    /// either place.
    private static func numericResponseCode(_ name: String,
                                           in lines: [IMAPUntaggedResponse],
                                           or completion: IMAPTaggedResponse) -> UInt64? {
        for line in lines {
            if let value = numericResponseCode(name, in: line.tokens) { return value }
        }
        return numericResponseCode(name, in: completion.tokens)
    }

    static func numericResponseCode(_ name: String, in tokens: [IMAPToken]) -> UInt64? {
        guard let open = tokens.firstIndex(of: .bracketOpen),
              open + 2 < tokens.count,
              tokens[open + 1].stringValue?.uppercased() == name.uppercased(),
              case .number(let value) = tokens[open + 2] else { return nil }
        return value
    }

    // MARK: - The CONDSTORE path

    /// `CHANGEDSINCE` for what we already hold, a full fetch for what is new, and
    /// — when the server offered `CONDSTORE` but **not** `QRESYNC` — the
    /// fallback's set-difference for what is gone.
    ///
    /// That last clause is not an optimisation, it is the correctness of this
    /// path. `VANISHED (EARLIER)` only rides on a `SELECT … (QRESYNC …)`, and
    /// `QRESYNC` may only be sent when advertised, so on a CONDSTORE-only server
    /// no `VANISHED` ever arrives and an untagged `EXPUNGE` reports only what was
    /// deleted *during this session*. A message deleted between sessions would
    /// never be reported, and since the cursor advances afterwards, never
    /// revisited: permanent, silent loss. The set difference is the only thing
    /// that sees it, so it runs whenever `QRESYNC` did not.
    private func walkChangedSince(_ modSeq: UInt64,
                                  resume: IMAPMailboxSyncState?,
                                  selected: IMAPSelectedMailbox,
                                  hasQresync: Bool,
                                  changed: inout Set<String>,
                                  removed: inout Set<String>) async throws {
        let firstArrival = resume?.nextArrivalUID ?? 1
        // The change scan asks for `(UID FLAGS MODSEQ)` and stops below the first
        // arrival. Both halves of that matter: a flag change is overwhelmingly the
        // common trigger, and fetching `fullItems` for it would download an
        // envelope, a body structure and a header block for every one of, say,
        // 5 000 messages whose `\Seen` bit moved — on a timer tick. An arrival
        // genuinely needs the envelope; a flag change does not, and the two are
        // now separate commands rather than one expensive compromise.
        if firstArrival > 1 {
            let response = try await session.execute(IMAPCommand(
                "UID FETCH",
                [.atom("1:\(firstArrival - 1)"), Self.flagItems,
                 .list([.atom("CHANGEDSINCE"), .atom(String(modSeq))])],
                isExclusive: true))
            try collectRemovals(from: response.untagged, into: &removed)
            // Every line the server returned is, by construction, a change since
            // `modSeq`. No local comparison is applied: the server is
            // authoritative here and second-guessing it would drop a change whose
            // stored flags happen to match (a move, a keyword we do not map).
            for fetched in try Self.fetches(in: response.untagged) {
                guard let uid = Self.uid(of: fetched) else { continue }
                insertThread(for: fetched, uid: uid, into: &changed)
            }
        }

        try await walkArrivals(from: firstArrival, selected: selected,
                               changed: &changed, removed: &removed)

        guard !hasQresync else { return }
        guard let rescan = try await rescanFlags(below: firstArrival,
                                                 removed: &removed) else { return }
        // Removals only. The flag comparison is deliberately NOT applied here:
        // `CHANGEDSINCE` already answered "what changed", authoritatively and
        // without a window bound, and re-deriving it from stored flags would
        // *lose* the changes the fallback's comparison cannot see.
        insertSetDifferenceRemovals(rescan, into: &removed)
    }

    // MARK: - The fallback

    private func walkWithoutCondstore(resume: IMAPMailboxSyncState?,
                                      selected: IMAPSelectedMailbox,
                                      changed: inout Set<String>,
                                      removed: inout Set<String>) async throws {
        let firstArrival = resume?.nextArrivalUID ?? 1
        try await walkArrivals(from: firstArrival, selected: selected,
                               changed: &changed, removed: &removed)

        guard let rescan = try await rescanFlags(below: firstArrival,
                                                 removed: &removed) else { return }
        for fetched in rescan.fetched {
            guard let uid = Self.uid(of: fetched) else { continue }
            // The comparison is what keeps the fallback from reporting the whole
            // re-scan as changed, which is the obvious wrong implementation and
            // would flood the sync engine with every message on every tick.
            guard identity.knownFlags(uid) != fetched.flags else { continue }
            insertThread(for: fetched, uid: uid, into: &changed)
        }
        insertSetDifferenceRemovals(rescan, into: &removed)
    }

    // MARK: - Shared walks

    /// `UID FETCH <firstArrival>:* (…fullItems)`, or nothing at all when the
    /// server's own `[UIDNEXT n]` proves no message arrived.
    ///
    /// The skip is what makes a flag-only pass cheap end to end: without it every
    /// tick would still ask for `ENVELOPE BODYSTRUCTURE BODY.PEEK[…]` over a range
    /// the server has already told us is empty.
    private func walkArrivals(from firstArrival: UInt32,
                              selected: IMAPSelectedMailbox,
                              changed: inout Set<String>,
                              removed: inout Set<String>) async throws {
        // A missing UIDNEXT is not evidence of an empty tail, so it fetches.
        if let uidNext = selected.uidNext, uidNext <= firstArrival { return }
        let arrivals = try await session.execute(IMAPCommand(
            "UID FETCH",
            [.atom("\(firstArrival):*"), Self.fullItems],
            isExclusive: true))
        try collectRemovals(from: arrivals.untagged, into: &removed)
        for fetched in try Self.fetches(in: arrivals.untagged) {
            guard let uid = Self.uid(of: fetched) else { continue }
            insertThread(for: fetched, uid: uid, into: &changed)
        }
    }

    /// The bounded `(UID FLAGS)` re-scan below `firstArrival`, with the range it
    /// actually covered. `nil` when there is nothing below to re-scan — on a full
    /// walk the arrival fetch already returned every message and every flag.
    private struct FlagRescan {
        let low: UInt32
        let high: UInt32
        let fetched: [IMAPFetchResponse]
        let seen: Set<UInt32>
    }

    private func rescanFlags(below firstArrival: UInt32,
                             removed: inout Set<String>) async throws -> FlagRescan? {
        guard firstArrival > 1 else { return nil }
        let high = firstArrival - 1
        let low = high >= flagRescanWindow ? high - flagRescanWindow + 1 : 1
        let response = try await session.execute(IMAPCommand(
            "UID FETCH",
            [.atom("\(low):\(high)"), .list([.atom("UID"), .atom("FLAGS")])],
            isExclusive: true))
        try collectRemovals(from: response.untagged, into: &removed)
        let fetched = try Self.fetches(in: response.untagged)
        return FlagRescan(low: low, high: high, fetched: fetched,
                          seen: Set(fetched.compactMap(Self.uid)))
    }

    /// A UID we hold, inside the range the server just enumerated, that the server
    /// did not mention, is gone. This is the fallback's `VANISHED` — and, on a
    /// CONDSTORE-without-QRESYNC server, the fast path's only removal detection.
    private func insertSetDifferenceRemovals(_ rescan: FlagRescan,
                                             into removed: inout Set<String>) {
        for uid in identity.knownUIDs()
        where uid >= rescan.low && uid <= rescan.high && !rescan.seen.contains(uid) {
            if let thread = identity.threadID(uid) { removed.insert(thread) }
        }
    }
}
