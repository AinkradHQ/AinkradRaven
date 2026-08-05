import Foundation

/// A `sequence-set` / `uid-set` as RFC 3501 §9 and RFC 7162 spell it —
/// `12`, `12:14`, `12:14,20,31:33` — expanded to the numbers it names.
///
/// Written here rather than inside `IMAPDeltaStrategy` because the *lexer* hands
/// one of these over in two different shapes and neither is obvious:
///
/// - `12` is a `.number` token.
/// - `12:14,20` is a single `.atom`, because `:` and `,` are not in
///   `IMAPLexer`'s delimiter set.
///
/// A reader that only handled `.number` would silently see no removals at all
/// for a server that coalesces its `VANISHED` set — the plausible-but-wrong
/// output this type exists to make impossible.
enum IMAPSequenceSet {

    /// Ranges wider than this are refused rather than expanded.
    ///
    /// This is a memory bound, and it is load-bearing because the input is a
    /// remote server: `1:4294967295` is a syntactically valid `uid-set` and
    /// expanding it eagerly would allocate 4 billion `UInt32`s inside a sync
    /// pass. Refusing throws, and a throwing delta pass *holds* the cursor, so
    /// the cost of the refusal is one retry rather than lost state.
    static let maxRangeWidth: UInt32 = 100_000

    /// Every number named by the token stream, in no particular order.
    ///
    /// Throws rather than skipping on anything it cannot resolve. Under-reporting
    /// a `VANISHED` set means a message stays in the local store forever with no
    /// second chance — the server will not repeat the notification — so a partial
    /// answer is strictly worse than a failed pass that gets retried.
    /// An empty result throws, exactly as `uids(inText:)` does. That symmetry is
    /// the point: a `* VANISHED (EARLIER)` whose set is missing — every token
    /// consumed as the modifier list, or a truncated line — would otherwise
    /// resolve to an empty set and read as "nothing was deleted", which is a wrong
    /// answer wearing a correct answer's clothes. A throw holds the cursor and the
    /// pass is retried.
    static func uids(in tokens: [IMAPToken]) throws -> Set<UInt32> {
        var result: Set<UInt32> = []
        for token in tokens {
            switch token {
            case .number(let value):
                guard let uid = UInt32(exactly: value) else {
                    throw IMAPDeltaError.unresolvableSequenceSet(String(value))
                }
                result.insert(uid)
            case .atom(let text):
                try result.formUnion(uids(inText: text))
            default:
                continue
            }
        }
        guard !result.isEmpty else {
            throw IMAPDeltaError.unresolvableSequenceSet(
                tokens.compactMap(\.stringValue).joined(separator: " "))
        }
        return result
    }

    /// Parses one textual set. `*` is refused: it means "the highest number in
    /// the mailbox", which is not knowable from the set itself, and guessing a
    /// bound would either drop removals or invent them.
    static func uids(inText text: String) throws -> Set<UInt32> {
        var result: Set<UInt32> = []
        for element in text.split(separator: ",", omittingEmptySubsequences: true) {
            let bounds = element.split(separator: ":", omittingEmptySubsequences: false)
            guard bounds.count <= 2 else {
                throw IMAPDeltaError.unresolvableSequenceSet(String(element))
            }
            let parsed = try bounds.map { part -> UInt32 in
                guard let value = UInt32(part) else {
                    throw IMAPDeltaError.unresolvableSequenceSet(String(part))
                }
                return value
            }
            guard let first = parsed.first else {
                throw IMAPDeltaError.unresolvableSequenceSet(String(element))
            }
            let last = parsed.count == 2 ? parsed[1] : first
            // A server may write a descending range (`20:12`); RFC 3501 says the
            // two forms are equivalent, so normalise rather than refuse.
            let low = min(first, last)
            let high = max(first, last)
            guard high - low < Self.maxRangeWidth else {
                throw IMAPDeltaError.sequenceSetTooWide(String(element))
            }
            for uid in low...high { result.insert(uid) }
        }
        guard !result.isEmpty else {
            throw IMAPDeltaError.unresolvableSequenceSet(text)
        }
        return result
    }
}
