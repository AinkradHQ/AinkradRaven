import Foundation

/// RFC 2047 encoded-word support for RFC 5322 header field bodies (`Subject`,
/// and display names in `To`/`Cc`/`From`). Headers are ASCII-only by RFC
/// 5322; any non-ASCII header value must be wrapped as `=?UTF-8?B?<base64>?=`
/// or it is either mangled or rejected by a strict parser.
enum RFC2047 {
    private static let prefix = "=?UTF-8?B?"
    private static let suffix = "?="
    /// RFC 2047 caps a single encoded word at 75 characters, INCLUDING the
    /// `=?charset?encoding?` delimiters.
    private static let maxEncodedWordLength = 75

    /// Compiled once. The pattern is a compile-time constant and cannot fail to
    /// compile, so `try!` here is total — but building an NSRegularExpression on
    /// every call is not free, and `decode` runs per header.
    private static let encodedWordRegex = try! NSRegularExpression(
        pattern: "=\\?UTF-8\\?B\\?([A-Za-z0-9+/=]*)\\?=", options: [.caseInsensitive])

    /// Encodes `text` as one or more folded encoded-words if it contains any
    /// non-ASCII byte; returns `text` unchanged if it is pure ASCII (encoding
    /// an ASCII-only value is legal but needlessly ugly in some clients).
    ///
    /// Chunk boundaries fall on whole Unicode scalar boundaries — never
    /// inside a scalar's multi-byte UTF-8 encoding — so multiple encoded
    /// words concatenated back together (per RFC 2047 §2's folding rule:
    /// whitespace between adjacent encoded words carrying the same charset/
    /// encoding is not significant) always decode to valid UTF-8. Each word
    /// individually still decodes to valid UTF-8 on its own for any
    /// non-folding-aware decoder, since a scalar's bytes are never split
    /// across a word boundary.
    static func encode(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 > 0x7F }) else { return text }

        let overhead = prefix.utf8.count + suffix.utf8.count
        let maxBase64Chars = maxEncodedWordLength - overhead
        // Base64 emits 4 output characters per 3 input bytes; round down to
        // the largest byte count whose base64 form still fits the budget.
        let maxBytesPerChunk = max(3, (maxBase64Chars / 4) * 3)

        var words: [String] = []
        var chunk: [UInt8] = []
        for scalar in text.unicodeScalars {
            let scalarBytes = Array(String(scalar).utf8)
            if !chunk.isEmpty && chunk.count + scalarBytes.count > maxBytesPerChunk {
                words.append(makeWord(chunk))
                chunk = []
            }
            chunk.append(contentsOf: scalarBytes)
        }
        if !chunk.isEmpty { words.append(makeWord(chunk)) }

        // RFC 2047 folding: adjacent encoded words separated only by CRLF +
        // whitespace are joined by decoders before base64-decoding, so a
        // scalar's bytes split across a chunk boundary are not actually
        // possible here (chunks never split a scalar) — this is purely
        // header-line-length hygiene.
        return words.joined(separator: "\r\n ")
    }

    private static func makeWord(_ bytes: [UInt8]) -> String {
        prefix + Data(bytes).base64EncodedString() + suffix
    }

    /// Decodes a header value that may contain zero or more RFC 2047
    /// `=?UTF-8?B?...?=` encoded words (optionally folded across lines),
    /// interleaved with literal text. Used by tests to verify `encode`
    /// round-trips; not required by any send path today.
    static func decode(_ header: String) -> String {
        guard header.contains("=?") else { return header }
        let ns = header as NSString
        let matches = Self.encodedWordRegex.matches(in: header, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return header }

        var pieces: [String] = []
        var pendingBytes = Data()
        var lastEnd = 0

        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            pieces.append(String(data: pendingBytes, encoding: .utf8) ?? "")
            pendingBytes = Data()
        }

        for match in matches {
            let between = ns.substring(with: NSRange(location: lastEnd,
                                                      length: match.range.location - lastEnd))
            if between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Folding whitespace between two encoded words: keep
                // accumulating bytes across the boundary rather than
                // decoding each word to UTF-8 independently, so a scalar
                // whose bytes happened to land either side of a fold still
                // decodes correctly.
            } else {
                flushBytes()
                pieces.append(between)
            }
            let base64 = ns.substring(with: match.range(at: 1))
            if let data = Data(base64Encoded: base64) {
                pendingBytes.append(data)
            }
            lastEnd = match.range.location + match.range.length
        }
        flushBytes()
        pieces.append(ns.substring(from: lastEnd))
        return pieces.joined()
    }
}
