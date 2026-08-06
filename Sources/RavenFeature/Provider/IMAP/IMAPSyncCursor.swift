import Foundation

/// One mailbox's durable IMAP sync position.
///
/// `uidValidity` is stored **with** the position rather than beside it, and that
/// pairing is the whole point of the type: a UID is only meaningful inside the
/// `UIDVALIDITY` generation it was observed in. Keeping them apart is what makes
/// "reuse a UID across a validity change" expressible, and a client that does
/// that silently fetches the wrong messages — or worse, `STORE`s flags onto
/// them.
struct IMAPMailboxSyncState: Equatable, Sendable, Codable {
    /// The generation this position belongs to. Any change means every UID
    /// below is meaningless and the mailbox must be walked again.
    var uidValidity: UInt32

    /// The `UIDNEXT` observed at the end of the last completed pass — i.e. the
    /// lowest UID that has never been seen. `1` means "nothing walked yet",
    /// which is also the correct starting point for a full walk, so there is no
    /// separate "unwalked" sentinel to get wrong.
    var uidNext: UInt32

    /// The `HIGHESTMODSEQ` observed, when the server offers `CONDSTORE`.
    /// `nil` means "not offered, or not yet observed" — never `0`, because
    /// `CHANGEDSINCE 0` is a legal command that means something different from
    /// "we have no modseq".
    var highestModSeq: UInt64?

    init(uidValidity: UInt32, uidNext: UInt32 = 1, highestModSeq: UInt64? = nil) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
    }

    /// The first UID a delta pass should ask for. Named separately from
    /// `uidNext` because the arrival walk (`UID FETCH <n>:*`) is the only place
    /// it is used and the off-by-one belongs here rather than at each call site.
    var nextArrivalUID: UInt32 { uidNext }

    private enum CodingKeys: String, CodingKey {
        case uidValidity = "uidvalidity"
        case uidNext = "uidnext"
        case highestModSeq = "highestmodseq"
    }

    /// Lenient by the same rule `OutgoingMessage`'s decoder follows: a state
    /// written by a newer build must decode to a usable subset.
    ///
    /// `uidValidity` is the one field with no safe default — a position with no
    /// generation cannot be trusted at all — so its absence makes the *entry*
    /// undecodable, and `IMAPSyncCursor` drops that one mailbox rather than
    /// failing the whole cursor. A missing `uidNext` degrades to `1`, which
    /// costs one re-walk and cannot produce a wrong fetch.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uidValidity = try container.decode(UInt32.self, forKey: .uidValidity)
        uidNext = try container.decodeIfPresent(UInt32.self, forKey: .uidNext) ?? 1
        highestModSeq = try container.decodeIfPresent(UInt64.self, forKey: .highestModSeq)
    }
}

/// What a delta pass must do for one mailbox, given what the server just said
/// its `UIDVALIDITY` is.
///
/// A value rather than a `Bool`, because "must be re-walked" and "never synced"
/// lead to the same *fetch* but must not lead to the same *bookkeeping*: a
/// re-walk invalidates locally held UIDs for that mailbox and a first walk has
/// none to invalidate. `.rewalk` carries the generation it is replacing so the
/// event is reportable rather than merely acted on.
enum IMAPMailboxSyncDecision: Equatable, Sendable {
    /// No state for this mailbox at all.
    case fullWalk
    /// `UIDVALIDITY` changed. Everything stored for this mailbox under
    /// `previousUIDValidity` is void.
    case rewalk(previousUIDValidity: UInt32)
    /// The stored generation still matches; resume from `state`.
    case resume(IMAPMailboxSyncState)

    /// Whether a caller must walk the mailbox from UID 1. True for both
    /// `.fullWalk` and `.rewalk` — the point being that a `.rewalk` can never
    /// be answered by a cheap incremental fetch.
    var requiresFullWalk: Bool {
        switch self {
        case .fullWalk, .rewalk: return true
        case .resume: return false
        }
    }
}

/// Every mailbox's sync position, encoded into the one `String` that
/// `MailAccount.syncCursor` already is.
///
/// **No store schema change, deliberately.** `accounts` is a single document
/// holding an array, storage is sharded JSON, and M6's constraint is that IMAP's
/// own state (`UIDVALIDITY`, `UIDNEXT`, `HIGHESTMODSEQ`) goes *into* the existing
/// cursor string rather than into a new store shape. So this type is a codec, not
/// a model the store knows about.
///
/// The encoding is JSON in that string. Two consequences worth stating:
///
/// 1. A Gmail cursor is a bare `historyId` (`"981223"`), which is not a JSON
///    *object*, so `IMAPSyncCursor(encoded:)` reads it as an empty cursor rather
///    than as garbage. A cursor written by the wrong provider therefore costs a
///    backfill, never a wrong fetch.
/// 2. Unknown keys — at the top level, and inside each mailbox entry — are
///    ignored, and a mailbox entry this build cannot make sense of is dropped
///    while its siblings survive. That is the same forward-compatibility rule
///    `OutgoingMessage`, `MailAccount.ProviderKind` and `MailAccount.State`
///    follow, and for the same reason: one document holds every mailbox, so a
///    strict decode of one entry strands all of them.
struct IMAPSyncCursor: Equatable, Sendable, Codable {
    /// The format version this build writes. Read back but never enforced: a
    /// higher version from a future build still decodes to whatever subset of
    /// keys this build understands.
    static let currentVersion = 1

    /// Mailbox name (as the server spells it) → position.
    var mailboxes: [String: IMAPMailboxSyncState]

    /// The version found on decode, or `currentVersion` for a fresh cursor.
    /// Preserved so a round-trip through an older build does not silently
    /// claim to be the older format.
    var version: Int

    init(mailboxes: [String: IMAPMailboxSyncState] = [:], version: Int = IMAPSyncCursor.currentVersion) {
        self.mailboxes = mailboxes
        self.version = version
    }

    var isEmpty: Bool { mailboxes.isEmpty }

    // MARK: - Decisions

    /// What a pass must do for `mailbox`, without changing anything.
    ///
    /// Pure on purpose. Detection of a `UIDVALIDITY` change has to be available
    /// to a caller that wants to *report* it (and to log it) before any state is
    /// thrown away; an API that could only detect by mutating would make the
    /// report a side effect of the discard.
    func decision(for mailbox: String, uidValidity: UInt32) -> IMAPMailboxSyncDecision {
        guard let state = mailboxes[mailbox] else { return .fullWalk }
        guard state.uidValidity == uidValidity else {
            return .rewalk(previousUIDValidity: state.uidValidity)
        }
        return .resume(state)
    }

    /// Applies the server's reported `UIDVALIDITY` and returns the decision.
    ///
    /// On `.rewalk` the mailbox's position is replaced with a fresh one for the
    /// new generation — `uidNext` back to `1`, `highestModSeq` cleared — and
    /// **no other mailbox is touched**. Per-mailbox isolation is the property
    /// that matters: a single re-provisioned folder must not cost a full account
    /// re-walk.
    @discardableResult
    mutating func reconcile(mailbox: String, uidValidity: UInt32) -> IMAPMailboxSyncDecision {
        let decision = decision(for: mailbox, uidValidity: uidValidity)
        switch decision {
        case .resume:
            break
        case .fullWalk, .rewalk:
            mailboxes[mailbox] = IMAPMailboxSyncState(uidValidity: uidValidity)
        }
        return decision
    }

    /// Records a completed pass. Never called on a partial pass: M0's
    /// `syncDelta` correction is that a transient failure *holds* the cursor,
    /// and holding is expressed by not calling this.
    mutating func advance(mailbox: String, uidValidity: UInt32,
                          uidNext: UInt32, highestModSeq: UInt64? = nil) {
        var state = mailboxes[mailbox] ?? IMAPMailboxSyncState(uidValidity: uidValidity)
        if state.uidValidity != uidValidity {
            state = IMAPMailboxSyncState(uidValidity: uidValidity)
        }
        // Monotonic: a server that reports a lower UIDNEXT within the same
        // generation is either racing or wrong, and lowering the position would
        // re-deliver messages the user has already seen.
        state.uidNext = max(state.uidNext, uidNext)
        if let highestModSeq {
            state.highestModSeq = max(state.highestModSeq ?? 0, highestModSeq)
        }
        mailboxes[mailbox] = state
    }

    /// Forgets a mailbox entirely — for a folder that no longer exists on the
    /// server. Distinct from a re-walk: there is nothing left to walk.
    mutating func forget(mailbox: String) {
        mailboxes.removeValue(forKey: mailbox)
    }

    // MARK: - String codec

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case mailboxes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version))
            .flatMap { $0 } ?? IMAPSyncCursor.currentVersion
        let raw = (try? container.decodeIfPresent([String: LenientState].self, forKey: .mailboxes))
            .flatMap { $0 } ?? [:]
        mailboxes = raw.compactMapValues(\.state)
    }

    /// Wraps a mailbox entry so one undecodable entry costs that entry only.
    /// A `[String: IMAPMailboxSyncState]` decode would fail the whole
    /// dictionary — every mailbox stranded by one future-shaped row.
    private struct LenientState: Decodable {
        let state: IMAPMailboxSyncState?

        init(from decoder: Decoder) throws {
            state = try? IMAPMailboxSyncState(from: decoder)
        }
    }

    /// The string to store in `MailAccount.syncCursor`.
    ///
    /// Keys are sorted so the same cursor always encodes to the same bytes:
    /// an account document that re-saves an unchanged cursor should not look
    /// changed.
    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Reads a stored cursor string. Never fails: an unreadable, empty, absent
    /// or foreign (Gmail `historyId`) cursor is an *empty* cursor, which costs a
    /// backfill and cannot cause a wrong fetch. Throwing here would strand the
    /// account instead.
    init(encoded string: String?) {
        guard let string, !string.isEmpty,
              let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(IMAPSyncCursor.self, from: data) else {
            self.init()
            return
        }
        self = decoded
    }
}
