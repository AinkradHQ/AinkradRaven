import Foundation

/// A minimal, tolerant RFC 822/2045 (MIME) *decoder* for a raw message byte
/// blob — the counterpart to `GmailProvider.rfc822`'s encoder, which this
/// codebase never previously needed: Gmail's API hands back already-parsed
/// JSON (`GmailMapping`), so nothing here duplicates decoding logic that
/// already existed. It reuses every piece that DOES already exist for
/// header/body semantics — `RFC2047.decode` for encoded-word subjects/names,
/// `AddressListParser.parse` for `To`/`Cc`, `BodySanitizer.plainText(fromHTML:)`
/// for an HTML-only body — rather than re-implementing any of them.
///
/// Used by `EmlxParser` to decode the raw RFC822 bytes an `.emlx` file
/// carries, and independent of `.emlx` framing itself.
struct RFC822Message {
    var headers: [(name: String, value: String)]
    /// Preferred plain-text body: `text/plain` if present, else `text/html`
    /// sanitized down to text, else empty.
    var plainText: String
    var html: String?

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Every value for a repeated header (`Received` in real mail, though
    /// nothing here currently needs more than one occurrence of anything) —
    /// kept for completeness/tolerance rather than any current caller.
    func headerValues(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    var subject: String { header("Subject") ?? "" }
    var from: MailAddress? { header("From").flatMap { MailAddress(rfc5322: $0) } }
    var to: [MailAddress] { header("To").map(AddressListParser.parse) ?? [] }
    var cc: [MailAddress] { header("Cc").map(AddressListParser.parse) ?? [] }
    var messageID: String? { header("Message-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
    /// `References` header ids, trimmed of angle brackets — used by
    /// `LocalThreading`, which never falls back to subject matching.
    var references: [String] {
        (header("References") ?? "").split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .filter { !$0.isEmpty }
    }
    var inReplyTo: String? {
        header("In-Reply-To")?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }
    var date: Date? {
        guard let raw = header("Date") else { return nil }
        return Self.date(rfc822: raw)
    }

    /// The tolerant RFC 822 date reading, exposed so other decoders of the same
    /// header syntax reuse these formatters instead of growing a second list
    /// that accepts a different set of real-world spellings. `IMAPFetchParser`
    /// uses it for `ENVELOPE`'s date field, which is an RFC 2822 date-time
    /// string exactly like the `Date:` header it is copied from.
    static func date(rfc822 raw: String) -> Date? {
        rfc822DateFormatters.lazy.compactMap { $0.date(from: raw) }.first
    }

    private static let rfc822DateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// Parses raw RFC822 bytes: header block (CRLF or LF separated, with
    /// header folding on leading whitespace continuation lines), a blank
    /// line, then the body — recursed into MIME parts when `Content-Type` is
    /// `multipart/*`.
    static func parse(_ data: Data) -> RFC822Message {
        let (headerLines, bodyData) = splitHeaderBlock(data)
        let headers = unfoldAndParseHeaders(headerLines)
        let contentType = headerValue(headers, "Content-Type") ?? "text/plain"

        var plain: String?
        var html: String?
        collectBody(bodyData, contentType: contentType, headers: headers, plain: &plain, html: &html)

        let text = plain ?? html.map(BodySanitizer.plainText(fromHTML:)) ?? ""
        return RFC822Message(headers: headers.map { (name: $0.0, value: RFC2047.decode($0.1)) },
                             plainText: text, html: html)
    }

    // MARK: - Header block

    /// Finds the header/body boundary directly on the BYTES (never through a
    /// `String`, which can lossily re-encode arbitrary body bytes and
    /// desynchronize any offset computed from it) — the first `\r\n\r\n`, or
    /// `\n\n` for a lenient/old file. Falls back to "everything is headers,
    /// empty body" when neither is found, tolerating a malformed/truncated
    /// message rather than crashing.
    private static func splitHeaderBlock(_ data: Data) -> (String, Data) {
        let bytes = [UInt8](data)
        let crlfcrlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let lflf: [UInt8] = [0x0A, 0x0A]
        func firstIndex(of pattern: [UInt8]) -> Int? {
            guard bytes.count >= pattern.count else { return nil }
            for start in 0...(bytes.count - pattern.count) {
                if Array(bytes[start..<start + pattern.count]) == pattern { return start }
            }
            return nil
        }
        let split: (headerEnd: Int, bodyStart: Int)
        if let index = firstIndex(of: crlfcrlf) {
            split = (index, index + crlfcrlf.count)
        } else if let index = firstIndex(of: lflf) {
            split = (index, index + lflf.count)
        } else {
            split = (bytes.count, bytes.count)
        }
        let headerData = Data(bytes[0..<split.headerEnd])
        let bodyData = Data(bytes[split.bodyStart..<bytes.count])
        let headerText = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1) ?? ""
        return (headerText, bodyData)
    }

    /// Joins folded continuation lines (leading space/tab) back onto the
    /// previous header, then splits `Name: value`.
    private static func unfoldAndParseHeaders(_ block: String) -> [(String, String)] {
        // `components(separatedBy:)`, NOT `split(separator: Character)`: a
        // lone `"\n"` `Character` literal never matches inside a `"\r\n"`
        // sequence, because Swift's `Character` is an extended grapheme
        // cluster and `"\r\n"` collapses to exactly ONE such cluster. Every
        // header line here ends in `\r\n` (see `splitHeaderBlock`), so a
        // `Character`-based split would find no separators at all and treat
        // the entire header block as one line — silently merging every
        // header after the first into the first header's "value".
        // `components(separatedBy:)` matches `"\n"` as a substring instead,
        // which finds it inside `"\r\n"` correctly.
        let rawLines = block.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var lines: [String] = []
        for line in rawLines {
            if let first = line.first, (first == " " || first == "\t"), !lines.isEmpty {
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers.append((name, value))
        }
        return headers
    }

    private static func headerValue(_ headers: [(String, String)], _ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    // MARK: - Body / MIME parts

    private static func collectBody(_ data: Data, contentType: String,
                                     headers: [(String, String)],
                                     plain: inout String?, html: inout String?) {
        let lower = contentType.lowercased()
        if lower.hasPrefix("multipart/"), let boundary = parameter(contentType, "boundary") {
            for part in splitParts(data, boundary: boundary) {
                let (partHeaderLines, partBody) = splitHeaderBlock(part)
                let partHeaders = unfoldAndParseHeaders(partHeaderLines)
                let partType = headerValue(partHeaders, "Content-Type") ?? "text/plain"
                let decodedBody = decodeTransferEncoding(
                    partBody, encoding: headerValue(partHeaders, "Content-Transfer-Encoding"))
                collectBody(decodedBody, contentType: partType, headers: partHeaders,
                           plain: &plain, html: &html)
            }
            return
        }
        let decoded = decodeTransferEncoding(data, encoding: headerValue(headers, "Content-Transfer-Encoding"))
        let text = String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .isoLatin1) ?? ""
        if lower.hasPrefix("text/html") {
            html = html ?? text
        } else {
            plain = plain ?? text
        }
    }

    /// Internal rather than private so `IMAPFetchParser` decodes a fetched MIME
    /// part's `Content-Transfer-Encoding` through this exact implementation. The
    /// alternative was a second quoted-printable decoder, which is precisely the
    /// kind of duplication that drifts.
    static func decodeTransferEncoding(_ data: Data, encoding: String?) -> Data {
        switch encoding?.lowercased() {
        case "base64":
            let ascii = String(data: data, encoding: .ascii) ?? ""
            let compact = ascii.filter { !$0.isWhitespace }
            return Data(base64Encoded: compact) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .ascii) else { return data }
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "=" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\n" || text[next] == "\r" {
                    // Soft line break: skip the CRLF/LF it introduces.
                    index = text.index(after: next)
                    if index < text.endIndex, text[text.index(before: index)] == "\r",
                       text[index] == "\n" { index = text.index(after: index) }
                    continue
                }
                let hexEnd = text.index(index, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                let hex = text[text.index(after: index)..<hexEnd]
                if hex.count == 2, let byte = UInt8(hex, radix: 16) {
                    out.append(byte)
                    index = hexEnd
                    continue
                }
                out.append(UInt8(ascii: "="))
                index = text.index(after: index)
            } else {
                out.append(contentsOf: Array(String(char).utf8))
                index = text.index(after: index)
            }
        }
        return out
    }

    /// Splits a multipart body on `--boundary` lines, dropping the preamble
    /// before the first boundary and the epilogue after the closing
    /// `--boundary--`.
    private static func splitParts(_ data: Data, boundary: String) -> [Data] {
        guard let text = String(data: data, encoding: .isoLatin1) else { return [] }
        let marker = "--\(boundary)"
        let segments = text.components(separatedBy: marker)
        // First segment is preamble; last, if it starts with "--", is the
        // epilogue after the closing delimiter.
        guard segments.count > 1 else { return [] }
        var parts: [Data] = []
        for segment in segments.dropFirst() {
            if segment.hasPrefix("--") { continue } // closing delimiter
            var body = segment
            if body.hasPrefix("\r\n") { body.removeFirst(2) }
            else if body.hasPrefix("\n") { body.removeFirst(1) }
            // Trim the trailing CRLF the NEXT boundary line introduced.
            if body.hasSuffix("\r\n") { body.removeLast(2) }
            else if body.hasSuffix("\n") { body.removeLast(1) }
            parts.append(Data(body.utf8))
        }
        return parts
    }

    /// Extracts `name=value` (quoted or not) from a `Content-Type`-shaped
    /// header value.
    private static func parameter(_ header: String, _ name: String) -> String? {
        for piece in header.components(separatedBy: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("\(name)=") else { continue }
            var value = String(trimmed.dropFirst(name.count + 1))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value
        }
        return nil
    }
}
