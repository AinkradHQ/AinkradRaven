import Foundation

/// One complete SMTP reply — a three-digit code plus every text line that
/// carried it.
///
/// A reply is one line *or many*: RFC 5321 §4.2.1 spells a continued reply
/// `250-<text>CRLF` and the last line `250 <text>CRLF`, and the `EHLO` response
/// that tells us whether `STARTTLS` and `AUTH XOAUTH2` exist at all is always
/// the multiline form. A parser that reads only the first line therefore sees an
/// `EHLO` server with no extensions — plausible-looking, and wrong in the
/// direction that silently downgrades security.
struct SMTPReply: Equatable, Sendable {
    let code: Int
    /// The text of each line in order, code and separator stripped. A line with
    /// no text at all contributes an empty string, so `lines.count` is always the
    /// number of lines the server actually sent.
    let lines: [String]

    /// The whole reply as one line of prose, for an error message. Server-authored
    /// text only — nothing here ever sees a credential.
    var text: String { lines.joined(separator: " ") }

    /// `2yz`/`3yz`. `3yz` (`354`, `334`) is not a completion but it is not a
    /// failure either: it is the server asking for the next thing.
    var isPositive: Bool { (200..<400).contains(code) }
    /// `4yz` — a transient failure. Retryable: the same command may succeed later.
    var isTransient: Bool { (400..<500).contains(code) }
    /// `5yz` — permanent. Retrying is pointless and, for a send, is five more
    /// chances to be told the same no.
    var isPermanent: Bool { code >= 500 }
}

/// Why an SMTP exchange failed, or was refused before it was attempted.
///
/// **No case can carry a credential.** Every payload here is either a numeric
/// code, a mechanism name, or text the *server* wrote. That is checked by a
/// source-level tripwire in `SMTPSessionTests` as well as by running real
/// credentials through every failure path.
enum SMTPSessionError: Error, Equatable {
    /// A line that is not a reply: no three-digit code, a bad separator, or a
    /// continuation whose code differs from the reply it belongs to (which RFC
    /// 5321 forbids, and which is how a desynchronised stream first shows up).
    case malformedReply(String)
    /// A well-formed reply with the wrong code for this point in the dialogue.
    case unexpectedReply(code: Int, text: String)
    /// `4yz`. Retryable.
    case transientFailure(code: Int, text: String)
    /// `5yz`. Permanent.
    case permanentFailure(code: Int, text: String)
    /// The server did not advertise `STARTTLS` on a connection that must be
    /// upgraded before anything else happens. Refused here rather than continuing
    /// in plaintext.
    case startTLSUnadvertised
    /// The negotiation succeeded but the transport cannot perform an in-place
    /// handshake — see `NetworkTransport.startTLS()`. Reported as its own case so
    /// "this transport cannot" is never confused with "this server would not".
    case tlsUpgradeUnsupported
    /// `AUTH` was requested on a connection that is not encrypted. Refused before
    /// the first byte of the command, so the credential is never written.
    case notEncrypted
    /// No mechanism this credential can use was advertised. Carries the mechanism
    /// name, never the credential.
    case mechanismUnavailable(String)
    /// The server refused the credential. Permanent.
    case authenticationRefused(code: Int, text: String)
    /// The message data was fully transmitted but the server's verdict never
    /// arrived — the connection broke, or answered nonsense, *after* `DATA` had
    /// been accepted. Whether the message went out is genuinely unknown, and this
    /// case is how that is reported instead of guessed at. See
    /// `SMTPSession.finishData`.
    case outcomeUnknown(String)

    /// How the `Outbox` should treat this failure. The mapping is the whole point
    /// of the 4xx/5xx split: a transient failure becomes the ordinary
    /// `.providerFailed` the drain already retries with backoff, a permanent one
    /// becomes `.sendRefused` (dead-lettered at once, not retried to exhaustion),
    /// and an unknown outcome becomes `.sendOutcomeUnknown`, which the drain holds
    /// for review rather than resending.
    var mailError: MailError {
        switch self {
        case .transientFailure(let code, let text):
            return .providerFailed(status: code, message: text)
        case .permanentFailure(let code, let text),
             .authenticationRefused(let code, let text),
             .unexpectedReply(let code, let text):
            return .sendRefused(status: code, message: text)
        case .outcomeUnknown(let detail):
            return .sendOutcomeUnknown(message: detail)
        case .malformedReply(let detail):
            return .providerFailed(status: -1, message: detail)
        case .startTLSUnadvertised:
            return .sendRefused(status: -1, message: "the server did not offer STARTTLS")
        case .tlsUpgradeUnsupported:
            return .sendRefused(status: -1,
                                message: "this transport cannot upgrade a connection to TLS")
        case .notEncrypted:
            return .sendRefused(status: -1,
                                message: "refused to authenticate on an unencrypted connection")
        case .mechanismUnavailable(let mechanism):
            return .sendRefused(status: -1,
                                message: "the server did not offer SASL \(mechanism)")
        }
    }
}

/// Turns reply lines into an `SMTPReply`. Pure and `static`, so every rule below
/// is assertable without a transport.
enum SMTPReplyParser {
    /// One parsed reply line.
    struct Line: Equatable, Sendable {
        let code: Int
        let text: String
        /// `true` when the separator was `-`, i.e. at least one more line follows.
        let isContinuation: Bool
    }

    /// The most continuation lines one reply may carry before the stream is
    /// treated as broken. A server that never sends a final line would otherwise
    /// keep `readReply` reading forever.
    static let maximumLines = 128

    /// Parses one line, CRLF already stripped.
    ///
    /// Accepted shapes, and nothing else:
    /// - `250 text` — final, with text.
    /// - `250-text` — continuation.
    /// - `250` — final, empty text. Rare but legal, and a parser that demands a
    ///   separator hangs on the server that sends it.
    static func parseLine(_ line: String) throws -> Line {
        let characters = Array(line)
        guard characters.count >= 3 else {
            throw SMTPSessionError.malformedReply("a reply line shorter than its code: \(line)")
        }
        let digits = String(characters[0..<3])
        guard let code = Int(digits), digits.allSatisfy(\.isNumber), (100...599).contains(code) else {
            throw SMTPSessionError.malformedReply("a reply line with no status code: \(line)")
        }
        guard characters.count > 3 else { return Line(code: code, text: "", isContinuation: false) }
        let separator = characters[3]
        let text = String(characters[4...])
        switch separator {
        case " ": return Line(code: code, text: text, isContinuation: false)
        case "-": return Line(code: code, text: text, isContinuation: true)
        default:
            throw SMTPSessionError.malformedReply(
                "a reply line with an illegal separator after its code: \(line)")
        }
    }

    /// Assembles already-parsed lines into a reply, enforcing that every line
    /// carried the SAME code (RFC 5321 §4.2.1) and that exactly the last one was
    /// final. Both are how a desynchronised stream — two replies read as one —
    /// is caught rather than blended into something plausible.
    static func assemble(_ lines: [Line]) throws -> SMTPReply {
        guard let first = lines.first else {
            throw SMTPSessionError.malformedReply("an empty reply")
        }
        for (index, line) in lines.enumerated() {
            guard line.code == first.code else {
                throw SMTPSessionError.malformedReply(
                    "a continuation line with code \(line.code) inside a \(first.code) reply")
            }
            let shouldContinue = index < lines.count - 1
            guard line.isContinuation == shouldContinue else {
                throw SMTPSessionError.malformedReply(
                    "a reply whose line \(index + 1) of \(lines.count) is "
                        + (shouldContinue ? "final" : "a continuation"))
            }
        }
        return SMTPReply(code: first.code, lines: lines.map(\.text))
    }

    /// Convenience for tests and for parsing a recorded fixture: a whole reply's
    /// CRLF-separated text at once.
    static func parse(_ text: String) throws -> SMTPReply {
        // Only the trailing empty component (the one the final CRLF produces) is
        // dropped. An empty line in the MIDDLE is not smoothed away: that is a
        // malformed reply and must be reported as one.
        var raw = text.components(separatedBy: "\r\n")
        while raw.last?.isEmpty == true { raw.removeLast() }
        return try assemble(try raw.map(parseLine))
    }
}
