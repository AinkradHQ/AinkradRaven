import Foundation

/// One lexical unit of an IMAP4rev1 server response.
///
/// The token stream is deliberately **flat**: lists and response codes appear as
/// explicit open/close tokens rather than as a nested value tree. Shaping them
/// into a tree is the parser's job (Task 10's `FETCH` parsing), and keeping the
/// lexer flat is what lets it be resumable — it can emit a `listOpen` the moment
/// the byte arrives without waiting for the matching `)`, which may be in a
/// later `read()`.
///
/// `[` and `]` are treated as delimiters unconditionally, even though RFC 3501's
/// `ATOM_CHAR` permits `[` inside an atom. Both real uses of a bracket are
/// structural — `* OK [UNSEEN 12]` response codes and `BODY[HEADER.FIELDS (…)]`
/// fetch items — so `BODY[1]` lexes as `atom("BODY"), bracketOpen, number(1),
/// bracketClose`, which is exactly the shape a fetch parser wants. The
/// alternative (atom-with-brackets) would force every consumer to re-split the
/// atom, i.e. to re-lex.
enum IMAPToken: Sendable, Equatable {
    /// An unquoted, non-numeric atom, verbatim and case-preserved. Includes the
    /// `*` of an untagged response, the `+` of a continuation request, and
    /// backslash flags such as `\Seen`.
    case atom(String)
    /// An atom made entirely of digits and small enough for `UInt64`. Emitted
    /// separately because message counts, UIDs, sizes and literal lengths are
    /// numbers everywhere upstream; an over-long digit run stays an `atom` so
    /// no information is lost.
    case number(UInt64)
    /// The unquoted atom `NIL`, case-insensitively. A *quoted* `"NIL"` is a
    /// string and stays `.quoted` — conflating the two would turn a message
    /// whose subject is literally `NIL` into a missing subject.
    case nilValue
    /// A quoted string with its surrounding quotes removed and `\"`/`\\`
    /// unescaped.
    case quoted(String)
    /// The payload of a `{n}` literal: `n` **opaque** bytes. These bytes are
    /// never re-tokenised — see `IMAPLexer` for why that is the crux of this
    /// type.
    case literal(Data)
    case listOpen
    case listClose
    case bracketOpen
    case bracketClose
    /// The CRLF ending a response line. Kept as a token rather than dropped
    /// because IMAP is line-framed above the token level: the command channel
    /// needs to know where a tagged completion ends, and a parser needs a
    /// terminator that a literal's embedded CRLFs cannot forge.
    case endOfLine
}

extension IMAPToken: CustomStringConvertible {
    var description: String {
        switch self {
        case .atom(let value): return "atom(\(value))"
        case .number(let value): return "number(\(value))"
        case .nilValue: return "NIL"
        case .quoted(let value): return "quoted(\(value.debugDescription))"
        case .literal(let data): return "literal(\(data.count) bytes)"
        case .listOpen: return "("
        case .listClose: return ")"
        case .bracketOpen: return "["
        case .bracketClose: return "]"
        case .endOfLine: return "CRLF"
        }
    }
}

extension IMAPToken {
    /// The text of a token that carries one, for callers that treat astrings
    /// uniformly (atom / quoted / literal are interchangeable in most IMAP
    /// grammar positions). `nil` for structural tokens, so a caller cannot
    /// silently read a `)` as an empty string.
    var stringValue: String? {
        switch self {
        case .atom(let value), .quoted(let value): return value
        case .number(let value): return String(value)
        case .literal(let data): return String(data: data, encoding: .utf8)
        case .nilValue, .listOpen, .listClose, .bracketOpen, .bracketClose, .endOfLine:
            return nil
        }
    }
}
