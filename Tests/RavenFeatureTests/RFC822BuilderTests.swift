import Testing
import Foundation
@testable import RavenFeature

/// `RFC822Builder` is the backend-independent half of what used to be
/// `GmailProvider.rfc822`: everything except Gmail's `Bcc` policy and its
/// base64url `raw` encoding. These tests pin the two properties that make the
/// extraction worth anything — that the builder's output is exactly what Gmail
/// uploads (so IMAP `APPEND`/SMTP submission cannot drift from it), and that
/// the `Bcc` decision really is the caller's rather than baked in.
@Suite("Generic RFC822 assembly")
struct RFC822BuilderTests {
    private let to = MailAddress(email: "b@example.test", name: "Bee")
    private let blind = MailAddress(email: "blind@example.test")

    private func build(_ message: OutgoingMessage, includeBccHeader: Bool = true) -> String {
        RFC822Builder.message(
            message, includeBccHeader: includeBccHeader, identityLookup: { _ in nil })
    }

    @Test("the builder's output is byte-identical to what Gmail base64url encodes")
    func gmailIsTheBuilderPlusEncoding() {
        // The whole point of the split. A boundary is a fresh UUID per call, so
        // the two runs cannot be compared directly — normalise the boundary
        // tokens, then require exact equality of everything else.
        let message = OutgoingMessage(
            to: [to], cc: [MailAddress(email: "c@example.test")], bcc: [blind],
            subject: "Subject 1", bodyText: "Body 1",
            attachments: [OutgoingAttachment(
                filename: "a.pdf", mimeType: "application/pdf", data: Data("bytes".utf8))])

        let direct = normalisedBoundaries(build(message))
        let viaGmail = normalisedBoundaries(
            GmailMapping.decodeBase64URL(
                GmailProvider.rfc822(message, identityLookup: { _ in nil })) ?? "")

        #expect(direct.isEmpty == false)
        #expect(direct == viaGmail)
    }

    @Test("includeBccHeader: false suppresses the Bcc header and nothing else")
    func bccIsTheCallersDecision() {
        // Task 15's SMTP path names blind recipients in the envelope, so it must
        // NOT transmit the header. Everything else about the message stays put.
        let message = OutgoingMessage(
            to: [to], cc: [MailAddress(email: "c@example.test")], bcc: [blind],
            subject: "Subject 1", bodyText: "Body 1")

        let withHeader = build(message, includeBccHeader: true)
        let without = build(message, includeBccHeader: false)

        #expect(withHeader.contains("\r\nBcc: blind@example.test\r\n"))
        #expect(without.lowercased().contains("bcc:") == false)
        #expect(without.contains("\r\nCc: c@example.test\r\n"))
        #expect(without.contains("Content-Type: multipart/alternative;"))
        #expect(normalisedBoundaries(withHeader)
            .replacingOccurrences(of: "Bcc: blind@example.test\r\n", with: "")
            == normalisedBoundaries(without))
    }

    @Test("a plain message is multipart/alternative with base64 parts and CRLF throughout")
    func plainMessageStructure() {
        let raw = build(OutgoingMessage(to: [to], subject: "Subject 1", bodyText: "Body 1"))

        #expect(raw.contains("Content-Type: multipart/alternative;"))
        #expect(raw.contains("multipart/mixed") == false)
        #expect(raw.contains("Content-Type: text/plain; charset=UTF-8\r\n"))
        #expect(raw.contains("Content-Type: text/html; charset=UTF-8\r\n"))
        #expect(raw.contains("Content-Transfer-Encoding: base64"))
        // The typed text is base64d, not emitted raw under an implicit 7bit.
        #expect(raw.contains("Body 1") == false)
        #expect(raw.contains(Data("Body 1".utf8).base64EncodedString()))
        // No bare LF anywhere: RFC 2046 boundary recognition depends on CRLF.
        #expect(bareLineFeedCount(raw) == 0)
    }

    @Test("attachments and an ICS reply share one outer multipart/mixed with a distinct boundary")
    func mixedWrapperStructure() {
        let message = OutgoingMessage(
            to: [to], subject: "Subject 1", bodyText: "Body 1",
            attachments: [OutgoingAttachment(
                filename: "a.pdf", mimeType: "application/pdf", data: Data("bytes".utf8))],
            icsReply: ICSReply(icsText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR"))
        let raw = build(message)

        #expect(raw.contains("Content-Type: multipart/mixed;"))
        #expect(raw.contains("Content-Type: multipart/alternative;"))
        #expect(raw.contains("Content-Type: application/pdf; name=\"a.pdf\""))
        #expect(raw.contains("Content-Type: text/calendar; method=REPLY; charset=UTF-8"))

        let boundaries = Set(boundaryTokens(raw))
        #expect(boundaries.count == 2)
        #expect(bareLineFeedCount(raw) == 0)
    }

    @Test("the builder names no backend")
    func builderIsBackendIndependent() throws {
        // A guard against the extraction quietly regrowing a Gmail dependency:
        // asserted on the source text because that is exactly the criterion.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RavenFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/RavenFeature/MIME/RFC822Builder.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.isEmpty == false)
        #expect(source.lowercased().contains("gmail") == false)
    }

    // MARK: - Helpers

    private func boundaryTokens(_ raw: String) -> [String] {
        raw.components(separatedBy: "raven-").dropFirst().map { String($0.prefix(36)) }
    }

    /// Replaces each distinct `raven-<uuid>` token with a stable index, so two
    /// runs of the same input become comparable.
    private func normalisedBoundaries(_ raw: String) -> String {
        var result = raw
        var index = 0
        for token in boundaryTokens(raw) where result.contains("raven-\(token)") {
            result = result.replacingOccurrences(
                of: "raven-\(token)", with: "raven-BOUNDARY-\(index)")
            index += 1
        }
        return result
    }

    private func bareLineFeedCount(_ raw: String) -> Int {
        var count = 0
        var previous: UInt8 = 0
        for byte in Array(raw.utf8) {
            if byte == 0x0A && previous != 0x0D { count += 1 }
            previous = byte
        }
        return count
    }
}
