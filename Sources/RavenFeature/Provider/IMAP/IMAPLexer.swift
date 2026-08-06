import Foundation

/// Why a byte stream could not be turned into tokens. Every failure mode is a
/// *typed* case: the lexer is fed by a remote server, so "malformed" has to be a
/// value the session can log and fail a command with, never a `fatalError`, never
/// a `nil` that a caller reads as "no tokens yet", and never a spin.
enum IMAPLexerError: Error, Equatable {
    /// A `{n}` literal declared more bytes than `maxLiteralBytes`. Thrown while
    /// reading the *header* — before a single payload byte is buffered and
    /// before any allocation of size `n` — which is the whole point of the cap.
    case literalTooLarge(declared: UInt64, cap: Int)
    /// `{…}` whose contents are not a non-negative number (optionally suffixed
    /// with `+` for `LITERAL+`), or whose `}` is not followed by CRLF.
    case malformedLiteralHeader(String)
    /// A backslash in a quoted string followed by something other than `"` or
    /// `\`, or a CR/LF inside a quoted string. Both are illegal per RFC 3501 and
    /// both are silent-corruption risks if guessed at.
    case malformedQuotedString(String)
    /// A CR not followed by LF, or a bare LF. IMAP frames on CRLF; accepting
    /// half of it would let a literal's embedded newline forge a line boundary.
    case malformedLineEnding
    /// A single un-terminated construct grew past `maxUnterminatedBytes`. This
    /// is the unbounded-read guard for everything that is *not* a literal: a
    /// server that never sends CRLF, or never closes a quoted string, must cost
    /// bounded memory.
    case unterminatedTokenTooLong(cap: Int)
}

/// Turns IMAP server bytes into `IMAPToken`s, **incrementally**.
///
/// The transport hands back whatever arrived (`MailTransport.read()`), split at
/// arbitrary byte boundaries. So this lexer is resumable by construction: feed it
/// any chunking with `append(_:)`, take whatever is complete with
/// `drainTokens()`, and it retains the partial tail. The contract it guarantees,
/// and that `IMAPLexerTests` asserts over *every* split point of each fixture:
///
/// > the concatenated output of any sequence of `append`/`drainTokens` calls
/// > equals the output of one `append` of the whole buffer.
///
/// This is achieved by never emitting a token that a later byte could extend.
/// An atom at the end of the buffer is withheld until a delimiter proves it
/// finished; a lone `CR`, an unclosed `"`, and an incomplete `{n}\r\n` header are
/// all withheld the same way.
///
/// ## Literals are opaque, and that is the crux
///
/// After a `{n}` header the next `n` bytes are payload. They are copied out
/// wholesale and **never inspected**: a CRLF in them does not end a line, a `)`
/// does not close a list, a `"` does not open a string, and a `{` does not start
/// another literal. A lexer that re-scans literal bytes corrupts every message
/// body containing a brace — and does so only for *some* messages, which is the
/// worst possible failure shape. `IMAPLexerTests` pins this with a fixture whose
/// literal contains all four bytes.
///
/// ## Bounds
///
/// Two caps, both enforced here rather than by a caller, because the caller is
/// the layer that would have to allocate:
/// - `maxLiteralBytes` — checked against the declared `n` in the header.
/// - `maxUnterminatedBytes` — checked against the retained tail after each
///   drain, so an endless line or an endless quoted string cannot grow forever.
///
/// A lexer that has thrown stays failed: `drainTokens()` rethrows. Re-syncing a
/// corrupt IMAP stream is not possible (there is no framing to re-sync *to*), so
/// the only correct recovery is for the session to drop the connection.
struct IMAPLexer: Sendable {
    /// 32 MiB. Sized to hold the largest thing IMAP legitimately sends as one
    /// literal in Raven's usage — a fetched message part — while refusing a
    /// hostile or buggy `{999999999}`, which would be a ~1 GB allocation on a
    /// single wire token.
    static let defaultMaxLiteralBytes = 32 * 1024 * 1024
    /// 1 MiB. Generous for a real response line (long `BODYSTRUCTURE` and
    /// `FLAGS` lists are the big ones) and far below anything that matters as a
    /// memory footprint.
    static let defaultMaxUnterminatedBytes = 1024 * 1024

    let maxLiteralBytes: Int
    let maxUnterminatedBytes: Int

    private var buffer: [UInt8] = []
    /// Read cursor into `buffer`; the prefix before it is consumed and is
    /// dropped by `compact()` after each drain.
    private var cursor = 0
    /// Bytes still owed to the literal in progress, if any.
    private var literalRemaining = 0
    private var literalPayload: [UInt8] = []
    private var isReadingLiteral = false
    /// Sticky: once malformed, always malformed.
    private var failure: IMAPLexerError?

    init(maxLiteralBytes: Int = IMAPLexer.defaultMaxLiteralBytes,
         maxUnterminatedBytes: Int = IMAPLexer.defaultMaxUnterminatedBytes) {
        self.maxLiteralBytes = maxLiteralBytes
        self.maxUnterminatedBytes = maxUnterminatedBytes
    }

    // MARK: - Feeding

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(contentsOf: data)
    }

    /// True when bytes are retained that have not yet formed a token — i.e. the
    /// caller must `read()` again before expecting more output. A response that
    /// ended cleanly leaves this false, which is how a test tells "the fixture
    /// was fully consumed" from "the lexer swallowed a tail".
    var hasPartialToken: Bool { cursor < buffer.count || isReadingLiteral }

    /// Every token that is now complete, in order. Returns empty when the
    /// buffered bytes cannot yet form one.
    mutating func drainTokens() throws -> [IMAPToken] {
        if let failure { throw failure }
        var tokens: [IMAPToken] = []
        do {
            try lex(into: &tokens)
        } catch let error as IMAPLexerError {
            failure = error
            throw error
        }
        compact()
        if cursor < buffer.count, buffer.count - cursor > maxUnterminatedBytes {
            let error = IMAPLexerError.unterminatedTokenTooLong(cap: maxUnterminatedBytes)
            failure = error
            throw error
        }
        return tokens
    }

    /// Convenience for whole-buffer callers and for the reference side of the
    /// every-split-point test. Not used in production, where bytes always arrive
    /// in chunks.
    static func tokenize(_ data: Data,
                         maxLiteralBytes: Int = IMAPLexer.defaultMaxLiteralBytes,
                         maxUnterminatedBytes: Int = IMAPLexer.defaultMaxUnterminatedBytes)
        throws -> [IMAPToken] {
        var lexer = IMAPLexer(maxLiteralBytes: maxLiteralBytes,
                              maxUnterminatedBytes: maxUnterminatedBytes)
        lexer.append(data)
        return try lexer.drainTokens()
    }

    // MARK: - The scan

    private mutating func lex(into tokens: inout [IMAPToken]) throws {
        while true {
            if isReadingLiteral {
                guard consumeLiteralBytes(into: &tokens) else { return }
                continue
            }
            guard cursor < buffer.count else { return }
            switch buffer[cursor] {
            case Byte.space, Byte.tab:
                cursor += 1
            case Byte.cr:
                guard cursor + 1 < buffer.count else { return }
                guard buffer[cursor + 1] == Byte.lf else { throw IMAPLexerError.malformedLineEnding }
                tokens.append(.endOfLine)
                cursor += 2
            case Byte.lf:
                throw IMAPLexerError.malformedLineEnding
            case Byte.openParen:
                tokens.append(.listOpen)
                cursor += 1
            case Byte.closeParen:
                tokens.append(.listClose)
                cursor += 1
            case Byte.openBracket:
                tokens.append(.bracketOpen)
                cursor += 1
            case Byte.closeBracket:
                tokens.append(.bracketClose)
                cursor += 1
            case Byte.quote:
                guard try scanQuoted(into: &tokens) else { return }
            case Byte.openBrace:
                guard try scanLiteralHeader(into: &tokens) else { return }
            default:
                guard scanAtom(into: &tokens) else { return }
            }
        }
    }

    /// Returns false when more bytes are needed (the token is withheld).
    private mutating func scanAtom(into tokens: inout [IMAPToken]) -> Bool {
        var index = cursor
        while index < buffer.count, !Byte.isDelimiter(buffer[index]) { index += 1 }
        // End of buffer with no delimiter: a later byte could extend this atom,
        // so it is not yet a token.
        guard index < buffer.count else { return false }
        let text = String(decoding: buffer[cursor..<index], as: UTF8.self)
        cursor = index
        tokens.append(Self.classify(text))
        return true
    }

    static func classify(_ text: String) -> IMAPToken {
        if text.count == 3, text.uppercased() == "NIL" { return .nilValue }
        // 19 digits is the widest run that always fits UInt64; anything longer
        // (or with a leading zero, which is not a valid IMAP number) stays an
        // atom rather than being silently reinterpreted.
        if !text.isEmpty, text.count <= 19, text.allSatisfy(\.isASCII),
           text.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
           text.first != "0" || text == "0",
           let value = UInt64(text) {
            return .number(value)
        }
        return .atom(text)
    }

    private mutating func scanQuoted(into tokens: inout [IMAPToken]) throws -> Bool {
        var index = cursor + 1
        var bytes: [UInt8] = []
        while index < buffer.count {
            let byte = buffer[index]
            if byte == Byte.backslash {
                guard index + 1 < buffer.count else { return false }
                let next = buffer[index + 1]
                guard next == Byte.quote || next == Byte.backslash else {
                    throw IMAPLexerError.malformedQuotedString(
                        "illegal escape \\\(Character(UnicodeScalar(next)))")
                }
                bytes.append(next)
                index += 2
                continue
            }
            if byte == Byte.cr || byte == Byte.lf {
                throw IMAPLexerError.malformedQuotedString("CR or LF inside a quoted string")
            }
            if byte == Byte.quote {
                cursor = index + 1
                tokens.append(.quoted(String(decoding: bytes, as: UTF8.self)))
                return true
            }
            bytes.append(byte)
            index += 1
        }
        return false // unterminated so far; the cap check catches a runaway
    }

    /// Parses `{n}CRLF` and arms literal mode. Returns false when the header is
    /// not yet complete. Note what this does NOT do: it does not read, buffer or
    /// allocate the payload. The cap is applied to the declared `n` here, so a
    /// `{999999999}` costs nothing.
    private mutating func scanLiteralHeader(into tokens: inout [IMAPToken]) throws -> Bool {
        var index = cursor + 1
        var digits: [UInt8] = []
        var sawPlus = false
        while index < buffer.count, buffer[index] != Byte.closeBrace {
            let byte = buffer[index]
            if byte == Byte.plus, !digits.isEmpty, !sawPlus {
                // LITERAL+ / LITERAL- non-synchronising form. Servers do not
                // normally send it, but accepting it costs one branch and
                // rejecting it would be a hang-shaped bug if one does.
                sawPlus = true
            } else if byte >= Byte.zero, byte <= Byte.nine, !sawPlus {
                digits.append(byte)
            } else {
                throw IMAPLexerError.malformedLiteralHeader(
                    "unexpected byte in {…}: \(byte)")
            }
            index += 1
            // A header this long cannot be a number we would accept; fail now
            // rather than buffering toward the line cap.
            if digits.count > 19 {
                throw IMAPLexerError.malformedLiteralHeader("literal length has too many digits")
            }
        }
        guard index < buffer.count else { return false } // no `}` yet
        guard !digits.isEmpty, let declared = UInt64(String(decoding: digits, as: UTF8.self)) else {
            throw IMAPLexerError.malformedLiteralHeader("empty or unparseable literal length")
        }
        guard declared <= UInt64(maxLiteralBytes) else {
            throw IMAPLexerError.literalTooLarge(declared: declared, cap: maxLiteralBytes)
        }
        // `}` must be followed by CRLF; withhold until BOTH bytes are here, so a
        // chunk boundary landing between them cannot be mistaken for a
        // malformed header (that would break the every-split-point property).
        guard index + 2 < buffer.count else { return false }
        guard buffer[index + 1] == Byte.cr, buffer[index + 2] == Byte.lf else {
            throw IMAPLexerError.malformedLiteralHeader("{n} not followed by CRLF")
        }
        cursor = index + 3
        isReadingLiteral = true
        literalRemaining = Int(declared)
        literalPayload = []
        literalPayload.reserveCapacity(min(literalRemaining, 64 * 1024))
        var scratch: [IMAPToken] = []
        _ = consumeLiteralBytes(into: &scratch) // completes a `{0}` immediately
        tokens.append(contentsOf: scratch)
        return true
    }

    /// Copies up to `literalRemaining` bytes out of the buffer verbatim. Returns
    /// true when the literal completed (and its token was emitted).
    private mutating func consumeLiteralBytes(into tokens: inout [IMAPToken]) -> Bool {
        let available = buffer.count - cursor
        let take = min(literalRemaining, available)
        if take > 0 {
            literalPayload.append(contentsOf: buffer[cursor..<(cursor + take)])
            cursor += take
            literalRemaining -= take
        }
        guard literalRemaining == 0 else { return false }
        tokens.append(.literal(Data(literalPayload)))
        literalPayload = []
        isReadingLiteral = false
        return true
    }

    /// Drops the consumed prefix. Done once per drain rather than per token so a
    /// long response is not quadratic.
    private mutating func compact() {
        guard cursor > 0 else { return }
        if cursor >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.removeFirst(cursor)
        }
        cursor = 0
    }
}

/// The byte constants and the delimiter set, in one place. `}` is deliberately
/// NOT a delimiter: RFC 3501's `ATOM_CHAR` permits it, and treating it as one
/// would leave a stray `}` matching no scanner branch.
private enum Byte {
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let quote: UInt8 = 0x22
    static let plus: UInt8 = 0x2B
    static let zero: UInt8 = 0x30
    static let nine: UInt8 = 0x39
    static let openParen: UInt8 = 0x28
    static let closeParen: UInt8 = 0x29
    static let backslash: UInt8 = 0x5C
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D

    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case space, tab, cr, lf, openParen, closeParen,
             openBracket, closeBracket, openBrace, quote:
            return true
        default:
            return false
        }
    }
}
