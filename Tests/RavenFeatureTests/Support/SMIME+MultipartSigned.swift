import Foundation

@testable import RavenFeature

/// Test-only: no production path parses an outgoing `multipart/signed` back.
extension SMIME {
    /// Splits a raw `multipart/signed` MIME entity (the `Content-Type` line
    /// plus body, exactly what `GmailProvider.signedEnvelope` produces) into
    /// the canonical bytes of its first (signed-content) part and the raw
    /// signature bytes decoded out of its second (`application/
    /// pkcs7-signature`) part. Used by tests to exercise a full
    /// build-then-verify round trip through the same string the wire
    /// actually carries.
    /// `nil` when `raw` is not a well-formed two-part `multipart/signed`
    /// entity.
    static func parseMultipartSigned(contentTypeLine: String, body: String) -> (
        signedContent: Data, signature: Data
    )? {
        guard let boundary = boundaryParameter(of: contentTypeLine) else { return nil }
        let firstMarker = "--\(boundary)\r\n"
        let middleMarker = "\r\n--\(boundary)\r\n"
        let closingMarker = "\r\n--\(boundary)--"

        guard body.hasPrefix(firstMarker) else { return nil }
        let afterFirstMarker = body.index(body.startIndex, offsetBy: firstMarker.count)
        guard let middleRange = body.range(of: middleMarker, range: afterFirstMarker..<body.endIndex)
        else { return nil }
        let contentPart = String(body[afterFirstMarker..<middleRange.lowerBound])

        let afterMiddleMarker = middleRange.upperBound
        guard
            let closingRange = body.range(
                of: closingMarker, range: afterMiddleMarker..<body.endIndex)
        else { return nil }
        let signaturePart = String(body[afterMiddleMarker..<closingRange.lowerBound])

        guard contentPart.range(of: "\r\n\r\n") != nil else { return nil }
        let signedContent = Data(contentPart.utf8)

        guard let sigBlankLine = signaturePart.range(of: "\r\n\r\n") else { return nil }
        let base64Body = String(signaturePart[sigBlankLine.upperBound...])
            .replacingOccurrences(of: "\r\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let signature = Data(base64Encoded: base64Body) else { return nil }
        return (signedContent, signature)
    }

    private static func boundaryParameter(of contentTypeLine: String) -> String? {
        guard let range = contentTypeLine.range(of: "boundary=\"") else { return nil }
        let rest = contentTypeLine[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
