import Foundation

/// One IMAP4rev1 client command, described *structurally* rather than as a
/// pre-formatted string.
///
/// The reason it is not a string: a command argument that contains an 8-bit
/// byte, a CR/LF, or a NUL cannot be sent as a quoted string at all — it has to
/// become a `{n}` literal, and a synchronising literal splits the command into
/// two writes with a server round-trip (`+ `) between them. Only the session
/// knows whether `LITERAL+` was advertised and may therefore collapse that round
/// trip. So the command owns *what* to send and `wirePlan` owns *how*, and the
/// literal/continuation decision is made in exactly one place.
struct IMAPCommand: Sendable, Equatable {
    /// The command word, e.g. `CAPABILITY`, `SELECT`, `UID FETCH`. Sent verbatim.
    let name: String
    let arguments: [Argument]

    init(_ name: String, _ arguments: [Argument] = []) {
        self.name = name
        self.arguments = arguments
    }

    enum Argument: Sendable, Equatable {
        /// Sent verbatim with no quoting: sequence sets, flag names, fetch item
        /// names, `(UID FLAGS)` contents. Never use for server-supplied or
        /// user-supplied text.
        case atom(String)
        /// Sent as a quoted string with `"` and `\` escaped.
        case quoted(String)
        /// Sent as a `{n}` literal. The bytes are opaque and are never escaped.
        case literal(Data)
        /// A parenthesised list; elements are rendered by the same rules.
        case list([Argument])

        /// The safe default for arbitrary text (a mailbox name, a search term, a
        /// credential): a quoted string when RFC 3501 permits one, a literal
        /// otherwise. Quoted strings may not contain CR, LF, NUL or any 8-bit
        /// byte, and mailbox names in particular routinely do — a naive quote
        /// would either corrupt them or desynchronise the command stream.
        static func text(_ value: String) -> Argument {
            let bytes = Data(value.utf8)
            let needsLiteral = bytes.contains { byte in
                byte == 0x00 || byte == 0x0A || byte == 0x0D || byte >= 0x80
            }
            return needsLiteral ? .literal(bytes) : .quoted(value)
        }
    }

    /// The bytes to write, split at every point where the client must wait for a
    /// `+ ` continuation request before continuing.
    ///
    /// `chunks[0]` is written when the command is issued; each later chunk is
    /// written by the read loop in response to one continuation request. With
    /// `LITERAL+` there is always exactly one chunk, which is the entire point of
    /// the extension.
    struct WirePlan: Sendable, Equatable {
        let chunks: [Data]
        /// How many `+ ` continuation requests this command expects.
        var expectedContinuations: Int { chunks.count - 1 }
    }

    /// - Parameter allowNonSynchronizingLiterals: pass true only when the
    ///   session has seen `LITERAL+` in the *current* capability list. Sending
    ///   `{n+}` to a server that never advertised it is a protocol violation
    ///   that desynchronises the connection, so this is never inferred here.
    func wirePlan(tag: String, allowNonSynchronizingLiterals: Bool) -> WirePlan {
        var chunks: [Data] = []
        var current = Data("\(tag) \(name)".utf8)
        for argument in arguments {
            current.append(0x20) // space
            append(argument, to: &current, chunks: &chunks,
                   allowNonSynchronizingLiterals: allowNonSynchronizingLiterals)
        }
        current.append(contentsOf: Self.crlf)
        chunks.append(current)
        return WirePlan(chunks: chunks)
    }

    private func append(_ argument: Argument,
                        to current: inout Data,
                        chunks: inout [Data],
                        allowNonSynchronizingLiterals: Bool) {
        switch argument {
        case .atom(let value):
            current.append(contentsOf: Data(value.utf8))
        case .quoted(let value):
            current.append(contentsOf: Data(Self.quote(value).utf8))
        case .literal(let payload):
            let marker = allowNonSynchronizingLiterals
                ? "{\(payload.count)+}" : "{\(payload.count)}"
            current.append(contentsOf: Data(marker.utf8))
            current.append(contentsOf: Self.crlf)
            if allowNonSynchronizingLiterals {
                // Non-synchronising: payload follows immediately, same write.
                current.append(payload)
            } else {
                // Synchronising: the server must answer `+ ` before the payload,
                // so the command is cut here and the payload starts the next
                // chunk.
                chunks.append(current)
                current = payload
            }
        case .list(let elements):
            current.append(0x28) // (
            for (index, element) in elements.enumerated() {
                if index > 0 { current.append(0x20) }
                append(element, to: &current, chunks: &chunks,
                       allowNonSynchronizingLiterals: allowNonSynchronizingLiterals)
            }
            current.append(0x29) // )
        }
    }

    static func quote(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for character in value {
            if character == "\"" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        escaped.append("\"")
        return escaped
    }

    private static let crlf: [UInt8] = [0x0D, 0x0A]
}

extension IMAPCommand: CustomStringConvertible {
    /// Literal payloads are shown as a byte count, never as bytes: `LOGIN` and
    /// `AUTHENTICATE` carry credentials in literals and this string is what a
    /// log line or an error would contain.
    var description: String {
        ([name] + arguments.map(Self.describe)).joined(separator: " ")
    }

    private static func describe(_ argument: Argument) -> String {
        switch argument {
        case .atom(let value): return value
        case .quoted(let value): return quote(value)
        case .literal(let payload): return "{\(payload.count) bytes}"
        case .list(let elements): return "(" + elements.map(describe).joined(separator: " ") + ")"
        }
    }
}

/// The completion status of a tagged response.
enum IMAPCommandStatus: String, Sendable, Equatable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
}

/// A tagged completion, plus the untagged lines that were unambiguously this
/// command's (see `IMAPSession.execute` for exactly when that is the case).
struct IMAPTaggedResponse: Sendable, Equatable {
    let tag: String
    let status: IMAPCommandStatus
    /// The human-readable remainder of the completion line, including any
    /// `[RESPONSE-CODE]`. Reconstructed from tokens, so spacing is normalised.
    let text: String
    /// The token stream of the completion line, without the tag, the status or
    /// the trailing CRLF — for callers that need the response code structurally.
    let tokens: [IMAPToken]
    /// Untagged lines attributed to this command, in arrival order.
    let untagged: [IMAPUntaggedResponse]
}

/// One untagged (`*`) response line as tokens. Parsing it into a domain value is
/// the business of later layers (`FETCH` in Task 10); the session only routes it.
struct IMAPUntaggedResponse: Sendable, Equatable {
    /// Tokens after the leading `*` and without the trailing CRLF.
    let tokens: [IMAPToken]

    /// The first token as an uppercased atom — `OK`, `EXISTS`, `FETCH`,
    /// `CAPABILITY`… For numbered responses (`* 12 FETCH …`) this is the number,
    /// so callers usually want `keyword` instead.
    var head: String? { tokens.first?.stringValue?.uppercased() }

    /// The response keyword, skipping a leading message number. `* 12 FETCH` and
    /// `* CAPABILITY` both answer with their word.
    var keyword: String? {
        if case .number = tokens.first { return tokens.dropFirst().first?.stringValue?.uppercased() }
        return head
    }

    var text: String { IMAPResponseText.render(tokens) }
}

/// Reassembles a readable string from a token line. Used for `IMAPTaggedResponse.text`
/// and for error messages; never for parsing decisions.
enum IMAPResponseText {
    static func render(_ tokens: [IMAPToken]) -> String {
        var text = ""
        var previous: IMAPToken?
        for token in tokens {
            if case .endOfLine = token { continue }
            if !text.isEmpty, Self.needsSpace(before: token, after: previous) { text.append(" ") }
            switch token {
            case .atom(let value), .quoted(let value): text.append(value)
            case .number(let value): text.append(String(value))
            case .nilValue: text.append("NIL")
            case .literal(let data): text.append(String(decoding: data, as: UTF8.self))
            case .listOpen: text.append("(")
            case .listClose: text.append(")")
            case .bracketOpen: text.append("[")
            case .bracketClose: text.append("]")
            case .endOfLine: break
            }
            previous = token
        }
        return text
    }

    /// Brackets and parens hug their contents, so `* NO [ALERT] text` reads back
    /// the way a server wrote it rather than as `[ ALERT ] text`.
    private static func needsSpace(before token: IMAPToken, after previous: IMAPToken?) -> Bool {
        switch token {
        case .listClose, .bracketClose: return false
        default: break
        }
        switch previous {
        case .listOpen, .bracketOpen: return false
        default: return true
        }
    }
}
