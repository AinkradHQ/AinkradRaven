import Foundation

@testable import RavenFeature

/// A parsed view of what `GmailProvider.rfc822` actually emits: the header
/// block, and each `multipart/alternative` part with its
/// `Content-Transfer-Encoding` undone.
///
/// Tests used to assert against the base64url-decoded raw string directly.
/// That was how `#expect(decoded.contains("Line one\nLine two"))` came to
/// assert the bare-LF DEFECT as correct, and how "CRLF throughout, not bare
/// LF" was written as `#expect(decoded.contains("\r\n"))` — a tautology for
/// any message with headers. Decoding the parts properly is what makes those
/// assertions able to fail.
struct DecodedRFC822 {
    let raw: String
    let headerBlock: String
    let plain: String
    let html: String

    init(_ message: OutgoingMessage) {
        let rawText = GmailMapping.decodeBase64URL(GmailProvider.rfc822(message)) ?? ""
        raw = rawText

        let split = rawText.range(of: "\r\n\r\n")
        let headers = split.map { String(rawText[rawText.startIndex..<$0.lowerBound]) } ?? rawText
        headerBlock = headers
        let bodyBlock = split.map { String(rawText[$0.upperBound...]) } ?? ""

        let boundary = Self.boundary(inHeaderBlock: headers)
        let parts =
            boundary.isEmpty
            ? []
            : bodyBlock.components(separatedBy: "--\(boundary)").dropFirst().dropLast()
        var decodedParts: [String: String] = [:]
        for part in parts {
            guard let separator = part.range(of: "\r\n\r\n") else { continue }
            let partHeaders = String(part[part.startIndex..<separator.lowerBound])
            let content = String(part[separator.upperBound...])
            let key = partHeaders.contains("text/html") ? "html" : "plain"
            decodedParts[key] = Self.decodeContent(content, headers: partHeaders)
        }
        plain = decodedParts["plain"] ?? ""
        html = decodedParts["html"] ?? ""
    }

    /// Every header field NAME present, so an injected `Bcc:` is detectable as
    /// a header rather than merely as a substring somewhere in the message.
    /// Continuation lines (folding whitespace) are not header starts.
    var headerNames: [String] {
        headerBlock.components(separatedBy: "\r\n").compactMap { line in
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                let colon = line.firstIndex(of: ":")
            else { return nil }
            return String(line[line.startIndex..<colon])
        }
    }

    /// One header's value, with any RFC 2047 encoded words decoded and folds
    /// unwrapped, so a test can assert on what a recipient would actually see.
    func header(_ name: String) -> String? {
        var value: String?
        for line in headerBlock.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if value != nil { value! += line }
                continue
            }
            if value != nil { break }
            if line.hasPrefix("\(name): ") {
                value = String(line.dropFirst(name.count + 2))
            }
        }
        return value.map(RFC2047.decode)
    }

    private static func boundary(inHeaderBlock headers: String) -> String {
        guard let start = headers.range(of: "boundary=\"") else { return "" }
        let rest = headers[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[rest.startIndex..<end])
    }

    private static func decodeContent(_ content: String, headers: String) -> String {
        guard headers.lowercased().contains("content-transfer-encoding: base64") else {
            return content
        }
        let joined =
            content
            .replacingOccurrences(of: "\r\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: joined) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
