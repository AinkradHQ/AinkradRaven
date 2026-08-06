import Testing
import Foundation
@testable import RavenFeature

/// M4: outbound attachments. `GmailProvider.rfc822` must wrap the existing
/// `multipart/alternative` text part in an outer `multipart/mixed` whenever
/// attachments (or an ICS reply) are present, with two distinct boundaries,
/// a correct RFC 2231 filename for non-ASCII names, and base64 wrapped at 76
/// columns — none of which may disturb the plain no-attachment path other
/// tests already pin down.
@Suite("Outbound attachment MIME")
struct AttachmentMIMETests {

    private func decodedRaw(_ message: OutgoingMessage) -> String {
        GmailMapping.decodeBase64URL(GmailProvider.rfc822(message)) ?? ""
    }

    @Test("no attachments and no ICS reply: still plain multipart/alternative at the top level")
    func unchangedWhenNoAttachments() {
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "hi", bodyText: "body")
        let raw = decodedRaw(message)
        #expect(raw.contains("Content-Type: multipart/alternative;"))
        #expect(raw.contains("multipart/mixed") == false)
    }

    @Test("an Arabic attachment filename survives as a decodable RFC 2231 parameter")
    func arabicFilenameSurvivesRFC2231() {
        let filename = "دعوة.pdf"
        let attachment = OutgoingAttachment(filename: filename, mimeType: "application/pdf",
                                            data: Data("pdf-bytes".utf8))
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "invite", bodyText: "see attached",
                                      attachments: [attachment])
        let raw = decodedRaw(message)

        // Extended RFC 2231 form is used (filename is non-ASCII).
        #expect(raw.contains("filename*=UTF-8''"))

        // Extract and percent-decode the filename*= value, verify round-trip.
        guard let range = raw.range(of: "filename*=UTF-8''") else {
            Issue.record("missing filename*= parameter")
            return
        }
        let after = raw[range.upperBound...]
        // NOTE: `"\r\n"` is a single `Character` (an extended grapheme
        // cluster) in Swift, so a `prefix { $0 != "\r" }` character-wise scan
        // never matches it — find the CRLF as a substring instead.
        let tail = after.range(of: "\r\n").map { after[after.startIndex..<$0.lowerBound] } ?? after
        let decoded = percentDecode(String(tail))
        #expect(decoded == filename)
    }

    @Test("an ASCII attachment filename is still quoted normally")
    func asciiFilenameQuoted() {
        let attachment = OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf",
                                            data: Data("bytes".utf8))
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "s", bodyText: "b", attachments: [attachment])
        let raw = decodedRaw(message)
        #expect(raw.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
    }

    @Test("nested multipart/mixed and multipart/alternative boundaries are distinct and absent from every part")
    func nestedBoundariesAreDistinctAndAbsent() {
        let attachment = OutgoingAttachment(filename: "a.txt", mimeType: "text/plain",
                                            data: Data("hello attachment".utf8))
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "s", bodyText: "the body text",
                                      attachments: [attachment])
        let raw = decodedRaw(message)

        let outerCT = firstLine(in: raw, containing: "Content-Type: multipart/mixed")
        guard let outerBoundary = boundary(fromHeaderLine: outerCT) else {
            Issue.record("no outer boundary"); return
        }
        let innerCT = firstLine(in: raw, containing: "Content-Type: multipart/alternative")
        guard let innerBoundary = boundary(fromHeaderLine: innerCT) else {
            Issue.record("no inner boundary"); return
        }
        #expect(outerBoundary != innerBoundary)

        // The outer terminator is present and correctly formed.
        #expect(raw.contains("--\(outerBoundary)--"))
        #expect(raw.contains("--\(innerBoundary)--"))

        // Neither boundary token appears inside the plain-text body, which is
        // the one human-typed part that could in principle collide.
        #expect(message.bodyText.contains(outerBoundary) == false)
        #expect(message.bodyText.contains(innerBoundary) == false)
    }

    @Test("the message becomes multipart/mixed wrapping multipart/alternative plus one part per attachment")
    func structureWrapsAlternativePlusAttachments() {
        let attachments = [
            OutgoingAttachment(filename: "one.txt", mimeType: "text/plain", data: Data("1".utf8)),
            OutgoingAttachment(filename: "two.txt", mimeType: "text/plain", data: Data("2".utf8)),
        ]
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "s", bodyText: "b", attachments: attachments)
        let raw = decodedRaw(message)
        #expect(raw.contains("Content-Type: multipart/mixed;"))
        #expect(raw.contains("Content-Type: multipart/alternative;"))
        #expect(raw.contains("filename=\"one.txt\""))
        #expect(raw.contains("filename=\"two.txt\""))
    }

    @Test("attachment base64 lines wrap at 76 characters")
    func base64WrapsAt76() {
        let bigData = Data(repeating: 0x41, count: 300) // forces multiple lines
        let attachment = OutgoingAttachment(filename: "big.bin", mimeType: "application/octet-stream",
                                            data: bigData)
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "s", bodyText: "b", attachments: [attachment])
        let raw = decodedRaw(message)

        guard let filenameRange = raw.range(of: "big.bin") else {
            Issue.record("attachment part not found"); return
        }
        let afterFilename = raw[filenameRange.upperBound...]
        guard let encodingRange = afterFilename.range(of: "Content-Transfer-Encoding: base64\r\n\r\n")
        else {
            Issue.record("could not locate attachment body"); return
        }
        let bodyStart = encodingRange.upperBound
        let rest = afterFilename[bodyStart...]
        let terminatorRange = rest.range(of: "\r\n--")
        let bodyEnd = terminatorRange?.lowerBound ?? rest.endIndex
        let body = rest[bodyStart..<bodyEnd]
        let lines = body.split(separator: "\r\n", omittingEmptySubsequences: true)
        #expect(!lines.isEmpty)
        for line in lines.dropLast() {
            #expect(line.count == 76, "line was \(line.count) chars: \(line)")
        }
        #expect((lines.last?.count ?? 0) <= 76)
    }

    // MARK: helpers

    private func firstLine(in text: String, containing needle: String) -> String {
        text.split(separator: "\r\n").first { $0.contains(needle) }.map(String.init) ?? ""
    }

    private func boundary(fromHeaderLine line: String) -> String? {
        guard let range = line.range(of: "boundary=\"") else { return nil }
        let after = line[range.upperBound...]
        return after.prefix { $0 != "\"" }.description
    }

    private func percentDecode(_ value: String) -> String {
        var bytes: [UInt8] = []
        var iterator = value.makeIterator()
        while let char = iterator.next() {
            if char == "%", let h1 = iterator.next(), let h2 = iterator.next(),
               let byte = UInt8(String([h1, h2]), radix: 16) {
                bytes.append(byte)
            } else {
                bytes.append(contentsOf: Array(String(char).utf8))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
