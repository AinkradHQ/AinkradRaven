import Foundation

/// `IMAPDeltaStrategy`'s shared readers: the two FETCH item lists all three
/// capability shapes draw from, and the untagged-line readers each walk feeds its
/// results into.
///
/// Split from `IMAPDeltaStrategy.swift` for the repo's line limit, the same way
/// `IMAPAuthTests`/`IMAPAuthChannelTests` were. It is a clean seam rather than an
/// arbitrary one: nothing here decides *which* UIDs to ask about — that is the
/// walk's job, in the other file — and everything here is about turning bytes the
/// server already sent into thread ids.
extension IMAPDeltaStrategy {

    // MARK: - FETCH item lists

    /// `(UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE BODY.PEEK[…])` — the item
    /// list BOTH paths use for a message they may not have seen before, so an
    /// arrival is described identically whichever walk found it. `BODY.PEEK`
    /// rather than `BODY`: fetching headers must not set `\Seen`.
    static let fullItems = IMAPCommand.Argument.list([
        .atom("UID"), .atom("FLAGS"), .atom("INTERNALDATE"),
        .atom("ENVELOPE"), .atom("BODYSTRUCTURE"),
        .atom("BODY.PEEK[HEADER.FIELDS (MESSAGE-ID REFERENCES IN-REPLY-TO)]"),
    ])

    /// `(UID FLAGS MODSEQ)` — the change scan's item list, a few tokens per
    /// message. `MODSEQ` is asked for because a `CHANGEDSINCE` response carries it
    /// anyway and naming it keeps the request self-describing; the parser tolerates
    /// it either way. Deliberately *not* `fullItems`: see `walkChangedSince`.
    static let flagItems = IMAPCommand.Argument.list([
        .atom("UID"), .atom("FLAGS"), .atom("MODSEQ"),
    ])

    static func fetches(in lines: [IMAPUntaggedResponse]) throws -> [IMAPFetchResponse] {
        try lines.compactMap(IMAPFetchParser.parse)
    }

    static func uid(of fetched: IMAPFetchResponse) -> UInt32? {
        fetched.uid.flatMap { UInt32(exactly: $0) }
    }

    func insertThread(for fetched: IMAPFetchResponse, uid: UInt32,
                              into changed: inout Set<String>) {
        // The fetched envelope first, the stored UID second. That order matters
        // for an arrival, which has no stored UID at all; reversing it would make
        // every arrival contribute nothing and the delta silently empty.
        if let thread = identity.threadIDForFetched(fetched) ?? identity.threadID(uid) {
            changed.insert(thread)
        }
    }

    /// Reads `* VANISHED [(EARLIER)] <uid-set>` and `* <n> EXPUNGE`.
    ///
    /// Both produce removals and neither is preferred: `VANISHED` is QRESYNC's
    /// batched form and `EXPUNGE` is what every other server sends, so a client
    /// that read only one would lose deletions against half the world.
    func collectRemovals(from lines: [IMAPUntaggedResponse],
                                 into removed: inout Set<String>) throws {
        for line in lines {
            if line.tokens.first?.stringValue?.uppercased() == "VANISHED" {
                // Drop the optional `(EARLIER)` modifier list before the set is
                // read; `EARLIER` is not a UID and must not be parsed as one.
                let set = Self.tokensOutsideLists(Array(line.tokens.dropFirst()))
                for uid in try IMAPSequenceSet.uids(in: set) {
                    if let thread = identity.threadID(uid) { removed.insert(thread) }
                }
                continue
            }
            guard case .number(let sequence)? = line.tokens.first,
                  line.tokens.dropFirst().first?.stringValue?.uppercased() == "EXPUNGE"
            else { continue }
            guard let uid = identity.uidForSequenceNumber(sequence),
                  let thread = identity.threadID(uid) else { continue }
            removed.insert(thread)
        }
    }

    /// Tokens at nesting depth zero. Used to strip a response modifier list from
    /// a `VANISHED` line without assuming it is present or that it is first.
    private static func tokensOutsideLists(_ tokens: [IMAPToken]) -> [IMAPToken] {
        var depth = 0
        var result: [IMAPToken] = []
        for token in tokens {
            switch token {
            case .listOpen: depth += 1
            case .listClose: depth = max(0, depth - 1)
            default: if depth == 0 { result.append(token) }
            }
        }
        return result
    }
}
