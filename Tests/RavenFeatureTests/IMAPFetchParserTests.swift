import Testing
import Foundation
@testable import RavenFeature

@Suite("IMAP FETCH response parsing")
struct IMAPFetchParserTests {

    // MARK: - Fixtures

    /// Shared with `IMAPFetchBodyStructureEdgeCaseTests` — see `IMAPFetchWire`.
    private func fixture(_ name: String) throws -> Data {
        try IMAPFetchWire.fixture(name)
    }

    private func untaggedResponses(_ data: Data) throws -> [IMAPUntaggedResponse] {
        try IMAPFetchWire.untaggedResponses(data)
    }

    private func parsed(_ name: String) throws -> [IMAPFetchResponse] {
        try IMAPFetchWire.parsed(name)
    }

    private func parsedLine(_ wire: String) throws -> IMAPFetchResponse {
        try IMAPFetchWire.parsedLine(wire)
    }

    // MARK: - ENVELOPE

    @Test("ENVELOPE yields subject, from/to/cc/bcc, date and Message-ID")
    func envelopeFields() throws {
        let responses = try parsed("imap-fetch-envelope")
        #expect(responses.count == 3)
        let first = try #require(responses.first)
        let envelope = try #require(first.envelope)

        #expect(first.uid == 101)
        #expect(envelope.subject == "Subject 1")
        #expect(envelope.from == [MailAddress(email: "a@example.test", name: "Sender One")])
        #expect(envelope.to == [MailAddress(email: "b@example.test", name: "Recipient Two")])
        #expect(envelope.cc == [MailAddress(email: "c@example.test", name: "Copy Three")])
        #expect(envelope.bcc == [MailAddress(email: "d@example.test", name: "Blind Four")])
        #expect(envelope.messageID == "m1@example.test")
        #expect(envelope.inReplyTo == nil)
        // 2026-01-05T09:15:00Z.
        #expect(envelope.parsedDate == Date(timeIntervalSince1970: 1_767_604_500))
        #expect(first.rfc822Size == 512)
        #expect(first.internalDate == Date(timeIntervalSince1970: 1_767_604_500))
    }

    @Test("an RFC 2047 encoded-word subject sent as a literal decodes")
    func encodedWordSubject() throws {
        let responses = try parsed("imap-fetch-envelope")
        let second = try #require(responses.count > 1 ? responses[1] : nil)
        let envelope = try #require(second.envelope)
        #expect(envelope.subject == "Subject 2")
        #expect(envelope.inReplyTo == "m0@example.test")
        #expect(envelope.messageID == "m2@example.test")
    }

    @Test("an unparseable ENVELOPE date does not drop the message")
    func unparseableDateKeepsMessage() throws {
        let responses = try parsed("imap-fetch-envelope")
        let second = try #require(responses.count > 1 ? responses[1] : nil)
        let third = try #require(responses.count > 2 ? responses[2] : nil)

        // Rung 1 failed (the raw string is retained so the gap is visible), so
        // INTERNALDATE carries it: 2026-01-06T10:00:00Z.
        #expect(second.envelope?.rawDate == "not-a-date")
        #expect(second.envelope?.parsedDate == nil)
        #expect(IMAPFetchParser.date(second) == Date(timeIntervalSince1970: 1_767_693_600))
        let secondMessage = IMAPFetchParser.message(second, id: "u102", threadID: "t2")
        #expect(secondMessage.rfc822MessageID == "m2@example.test")

        // Neither rung available: the epoch, and the message still exists.
        #expect(third.envelope?.rawDate == nil)
        #expect(third.internalDate == nil)
        #expect(IMAPFetchParser.date(third) == Date(timeIntervalSince1970: 0))
        let thirdMessage = IMAPFetchParser.message(third, id: "u103", threadID: "t3")
        #expect(thirdMessage.rfc822MessageID == "m3@example.test")
        // An empty ENVELOPE subject falls back the way `GmailMapping` does.
        #expect(thirdMessage.subject == "(no subject)")
    }

    // MARK: - FLAGS

    @Test("FLAGS map through the canonical vocabulary, with unread polarity inverted")
    func flagsMapToCanonicalVocabulary() throws {
        let responses = try parsed("imap-fetch-envelope")
        let first = try #require(responses.first)
        let second = try #require(responses.count > 1 ? responses[1] : nil)
        let third = try #require(responses.count > 2 ? responses[2] : nil)

        // `\Seen` present → not unread. `\Answered` and `\Recent` have no
        // canonical meaning and are dropped rather than leaked as raw strings.
        #expect(first.flags == [])
        #expect(second.flags == [.starred, .trash, .draft, .unread, .user("$Keyword1")])
        // No flags at all still means unread — the absence of `\Seen` is the signal.
        #expect(third.flags == [.unread])

        let firstMessage = IMAPFetchParser.message(first, id: "u101", threadID: "t1")
        #expect(firstMessage.isRead)
        #expect(firstMessage.isStarred == false)
        let secondMessage = IMAPFetchParser.message(second, id: "u102", threadID: "t2")
        #expect(secondMessage.isRead == false)
        #expect(secondMessage.isStarred)
        // Raw IMAP flag strings must never reach the domain.
        #expect(secondMessage.labelIDs.isEmpty)
        for flag in second.flags {
            #expect(flag.canonicalToken.contains("\\") == false,
                    "a raw IMAP flag string escaped as \(flag.canonicalToken)")
        }
    }

    @Test("individual flag translations")
    func individualFlagTranslations() {
        #expect(IMAPFetchParser.canonicalFlags(from: ["\\Seen"]) == [])
        #expect(IMAPFetchParser.canonicalFlags(from: ["\\Flagged"]) == [.unread, .starred])
        #expect(IMAPFetchParser.canonicalFlags(from: ["\\Seen", "\\Deleted"]) == [.trash])
        #expect(IMAPFetchParser.canonicalFlags(from: ["\\Seen", "\\Draft"]) == [.draft])
        // Case-insensitive: servers are free to spell them any way.
        #expect(IMAPFetchParser.canonicalFlags(from: ["\\SEEN", "\\flagged"]) == [.starred])
    }

    // MARK: - BODYSTRUCTURE

    @Test("a single-part message is part 1, fetched as BODY[TEXT]")
    func simpleBodyStructure() throws {
        let response = try #require(try parsed("imap-fetch-bodystructure-simple").first)
        let structure = try #require(response.bodyStructure)
        #expect(structure.partNumber == "1")
        #expect(structure.mimeType == "text/plain")
        #expect(structure.parameters == ["charset": "UTF-8"])
        #expect(structure.encoding == "7bit")
        #expect(structure.size == 8)
        #expect(structure.children.isEmpty)
        #expect(structure.attachments == [])

        let body = IMAPFetchParser.body(response, messageID: "u201")
        #expect(body.plainText == "Body one")
        #expect(body.html == nil)
    }

    @Test("multipart/alternative yields the plain part and the raw HTML part")
    func alternativeBodyStructure() throws {
        let response = try #require(try parsed("imap-fetch-bodystructure-alternative").first)
        let structure = try #require(response.bodyStructure)
        #expect(structure.mimeType == "multipart/alternative")
        // The top-level multipart is not addressable; its children are.
        #expect(structure.partNumber == nil)
        #expect(structure.children.map(\.partNumber) == ["1", "2"])
        #expect(structure.plainTextPart?.partNumber == "1")
        #expect(structure.htmlPart?.partNumber == "2")
        #expect(structure.attachments == [])

        let body = IMAPFetchParser.body(response, messageID: "u202")
        #expect(body.plainText == "Body one")
        // `html` is the ORIGINAL, byte-for-byte — "Show original" renders it and
        // `MessageBody.plainText` is the sanitized surface.
        #expect(body.html == "<p>Body one<script>x</script></p>")
    }

    @Test("an HTML-only message derives plainText through BodySanitizer")
    func htmlOnlyGoesThroughSanitizer() throws {
        let raw = "<p>Body one</p><script>alert(1)</script>"
        let wire = "* 1 FETCH (UID 205 BODYSTRUCTURE (\"TEXT\" \"HTML\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(raw.utf8.count) 1) "
            + "BODY[TEXT] {\(raw.utf8.count)}\r\n\(raw))\r\n"
        let response = try parsedLine(wire)
        let body = IMAPFetchParser.body(response, messageID: "u205")

        #expect(body.html == raw)
        #expect(body.plainText == BodySanitizer.plainText(fromHTML: raw))
        // The sanitizer's actual guarantee, restated as an assertion rather than
        // trusted: no markup and no script payload survives into plainText.
        #expect(body.plainText.contains("<") == false)
        #expect(body.plainText.contains("script") == false)
        #expect(body.plainText.contains("alert") == false)
        #expect(body.plainText.contains("Body one"))
    }

    @Test("multipart/mixed yields attachment metadata only")
    func mixedBodyStructureAttachmentMetadata() throws {
        let response = try #require(try parsed("imap-fetch-bodystructure-mixed").first)
        let structure = try #require(response.bodyStructure)
        #expect(structure.mimeType == "multipart/mixed")

        // Compared as a whole collection, so a wrong count cannot be masked.
        #expect(structure.attachments == [
            MailAttachment(attachmentID: "2", filename: "file-a.pdf",
                           mimeType: "application/pdf", size: 1234),
        ])
        let message = IMAPFetchParser.message(response, id: "u203", threadID: "t203")
        #expect(message.hasAttachments)
        #expect(message.attachments == structure.attachments)
        // Metadata only: no section for part 2 was fetched, and none was invented.
        #expect(response.sections["2"] == nil)
        #expect(response.sections.keys.sorted() == ["1"])
    }

    @Test("nested part numbers, quoted-printable decoding, and named-leaf attachments")
    func nestedBodyStructure() throws {
        let response = try #require(try parsed("imap-fetch-bodystructure-nested").first)
        let structure = try #require(response.bodyStructure)
        #expect(structure.mimeType == "multipart/mixed")
        #expect(structure.children.map(\.partNumber) == ["1", "2", "3"])
        #expect(structure.children.map(\.mimeType)
            == ["multipart/alternative", "application/octet-stream", "text/plain"])
        // The nested `multipart/alternative` IS addressable as part 1 (a
        // `BODY[1]` fetch returns the whole alternative); only the TOP-LEVEL
        // multipart is unnumbered, which is why it contributes no entry here.
        #expect(structure.preOrder.map(\.partNumber)
            == [nil, "1", "1.1", "1.2", "2", "3"])
        #expect(structure.plainTextPart?.partNumber == "1.1")
        #expect(structure.htmlPart?.partNumber == "1.2")
        #expect(structure.attachments == [
            MailAttachment(attachmentID: "2", filename: "file-b.bin",
                           mimeType: "application/octet-stream", size: 64),
        ])

        let body = IMAPFetchParser.body(response, messageID: "u204")
        // Part 3 is also `text/plain`; picking it would mean the walk is not
        // depth-first pre-order.
        #expect(body.plainText == "Body one")
        // `=20` decoded, so the part's Content-Transfer-Encoding was honoured.
        #expect(body.html == "<p>Body one</p>")
    }

    @Test("a text part's disposition is read one slot later than a non-text part's")
    func textPartDispositionOffset() throws {
        // A `text/*` part carries a required body-fld-lines before the extension
        // fields, so an inline-disposition filename sits at index 9, not 8.
        let wire = "* 1 FETCH (UID 206 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 8 1)"
            + "(\"TEXT\" \"CSV\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 20 2 NIL "
            + "(\"ATTACHMENT\" (\"FILENAME\" \"table-a.csv\")) NIL NIL) "
            + "\"MIXED\" (\"BOUNDARY\" \"b5\")))\r\n"
        let response = try parsedLine(wire)
        let structure = try #require(response.bodyStructure)
        #expect(structure.attachments == [
            MailAttachment(attachmentID: "2", filename: "table-a.csv",
                           mimeType: "text/csv", size: 20),
        ])
    }

    @Test("a multipart container with an attachment disposition is not itself an attachment")
    func multipartContainerIsNotAnAttachment() throws {
        // Real servers put `("ATTACHMENT" ("FILENAME" …))` on a multipart
        // container (a forwarded or signed sub-message). Counting it as an
        // attachment would list the container AND each of its leaves, so the UI
        // would offer to save the same bytes twice under two names.
        let wire = "* 1 FETCH (UID 207 BODYSTRUCTURE (((\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 8 1)"
            + "(\"APPLICATION\" \"PDF\" (\"NAME\" \"file-c.pdf\") NIL NIL \"BASE64\" 9 NIL "
            + "(\"ATTACHMENT\" (\"FILENAME\" \"file-c.pdf\")) NIL NIL) "
            + "\"MIXED\" (\"BOUNDARY\" \"b6\") "
            + "(\"ATTACHMENT\" (\"FILENAME\" \"forwarded.eml\"))) "
            + "\"MIXED\" (\"BOUNDARY\" \"b7\")))\r\n"
        let response = try parsedLine(wire)
        let structure = try #require(response.bodyStructure)
        let container = try #require(structure.children.first)
        // The container really does carry the disposition — the exclusion is a
        // decision about multiparts, not an accident of missing metadata.
        #expect(container.isMultipart)
        #expect(container.filename == "forwarded.eml")
        #expect(structure.attachments == [
            MailAttachment(attachmentID: "1.2", filename: "file-c.pdf",
                           mimeType: "application/pdf", size: 9),
        ])
    }

    // MARK: - Agreement with GmailMapping

    /// The plan's cross-provider check: for the *same* message shape, the IMAP
    /// part-selection rule must choose the same plain/HTML pair `GmailMapping`
    /// chooses. The shape is chosen to discriminate: the `multipart/mixed` holds
    /// a `multipart/alternative` AND a second, later `text/plain`, so a rule that
    /// searched only the top level, or took the last match, would pick "Body two"
    /// instead of "Body one" and this test would fail.
    @Test("a multipart/alternative inside multipart/mixed picks the pair GmailMapping picks")
    func agreesWithGmailPartSelection() throws {
        let response = try #require(try parsed("imap-fetch-bodystructure-nested").first)
        let imapBody = IMAPFetchParser.body(response, messageID: "shared")

        func part(_ mime: String, text: String) -> GmailMessageDTO.Payload {
            GmailMessageDTO.Payload(
                headers: [], mimeType: mime,
                body: GmailMessageDTO.Body(data: GmailMapping.base64URL(text),
                                           size: text.utf8.count),
                parts: nil)
        }
        let alternative = GmailMessageDTO.Payload(
            headers: [], mimeType: "multipart/alternative", body: nil,
            parts: [part("text/plain", text: "Body one"),
                    part("text/html", text: "<p>Body one</p>")])
        let attachment = GmailMessageDTO.Payload(
            headers: [], mimeType: "application/octet-stream", filename: "file-b.bin",
            body: GmailMessageDTO.Body(data: nil, size: 64, attachmentId: "a1"), parts: nil)
        let dto = GmailMessageDTO(
            id: "shared", threadId: "t", labelIds: [], snippet: nil, internalDate: "0",
            payload: GmailMessageDTO.Payload(
                headers: [], mimeType: "multipart/mixed", body: nil,
                parts: [alternative, attachment, part("text/plain", text: "Body two")]))
        let gmailBody = GmailMapping.body(dto)

        #expect(imapBody.plainText == gmailBody.plainText)
        #expect(imapBody.html == gmailBody.html)
        // Pinned literally as well, so the two agreeing on the WRONG part would
        // still fail rather than agree vacuously.
        #expect(imapBody.plainText == "Body one")
        #expect(imapBody.html == "<p>Body one</p>")
    }

    // MARK: - Tolerance

    @Test("a non-FETCH untagged line is skipped, not an error")
    func nonFetchLinesAreSkipped() throws {
        let responses = try untaggedResponses(Data("* 4 EXISTS\r\n* OK [UNSEEN 2] x\r\n".utf8))
        for response in responses {
            let fetch = try IMAPFetchParser.parse(response)
            #expect(fetch == nil, "\(response.text) was read as a FETCH")
        }
    }

    @Test("an unknown FETCH item is consumed without derailing the line")
    func unknownItemsAreTolerated() throws {
        let response = try parsedLine(
            "* 7 FETCH (MODSEQ (12345) UID 301 X-VENDOR (\"a\" \"b\") FLAGS (\\Seen))\r\n")
        #expect(response.sequenceNumber == 7)
        #expect(response.uid == 301)
        #expect(response.flags == [])
    }

    @Test("a truncated FETCH line throws rather than yielding a half-built value")
    func truncatedLineThrows() throws {
        // Three distinct truncation points, because they are three distinct
        // guards: inside a nested list, at a top-level value position, and at an
        // item-name position. A build that only threw from one of them would
        // silently hand a half-built response to a caller from the others.
        let cases = [
            "1 FETCH (UID 302 FLAGS (\\Seen",   // mid-list
            "1 FETCH (UID ",                     // value expected, none arrives
            "1 FETCH (",                         // item name expected
        ]
        for wire in cases {
            let response = IMAPUntaggedResponse(tokens: try IMAPLexer.tokenize(Data(wire.utf8)))
            #expect(throws: IMAPFetchParseError.truncated, "\(wire) did not throw") {
                _ = try IMAPFetchParser.parse(response)
            }
        }
    }

    @Test("References and In-Reply-To come from a fetched HEADER.FIELDS section")
    func headerFieldsSection() throws {
        let headerText = "References: <m0@example.test> <m1@example.test>\r\n"
            + "In-Reply-To: <m1@example.test>\r\n\r\n"
        let wire = "* 8 FETCH (UID 303 BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO)] "
            + "{\(headerText.utf8.count)}\r\n\(headerText))\r\n"
        let response = try parsedLine(wire)
        let headers = try #require(IMAPFetchParser.headers(response))
        #expect(headers.references == ["m0@example.test", "m1@example.test"])
        #expect(headers.inReplyTo == "m1@example.test")
        // A HEADER section is not a body section.
        #expect(response.sections.isEmpty)
    }

    @Test("a partial-fetch <offset> suffix does not change which section was read")
    func partialFetchOffsetIsIgnored() throws {
        let response = try parsedLine("* 9 FETCH (UID 304 BODY[TEXT]<0> {8}\r\nBody one)\r\n")
        #expect(response.sections["TEXT"] == Data("Body one".utf8))
    }
}
