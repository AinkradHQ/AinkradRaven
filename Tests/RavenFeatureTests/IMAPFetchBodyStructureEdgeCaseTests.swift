import Testing
import Foundation
@testable import RavenFeature

/// The three `BODYSTRUCTURE` behaviours that are easy to get wrong *silently* —
/// a misread extension-field slot, a dropped child, and a whole-body fallback
/// applied to a multipart. None of them fails loudly on the pre-fix code: each
/// produces a plausible-looking body tree or body text, which is exactly why
/// they get their own suite rather than living among the happy-path shapes in
/// `IMAPFetchParserTests`.
@Suite("IMAP BODYSTRUCTURE edge cases")
struct IMAPFetchBodyStructureEdgeCaseTests {

    // MARK: - Position-dependent extension fields

    /// RFC 3501 §7.4.2's `body-type-msg` carries ENVELOPE, BODY *and* LINES
    /// before the extension fields, so the disposition sits at index 11 — three
    /// slots later than a `body-type-basic`'s 8. Index 8 is the nested
    /// BODYSTRUCTURE *list*, and `parseDisposition` on a list whose first element
    /// is a string reads that string as a disposition TYPE, so the misread does
    /// not throw: it yields a nonsense `dispositionType` and no filename, and a
    /// forwarded `.eml` quietly stops being an attachment.
    ///
    /// The fixture deliberately ALSO carries a Content-Type `("NAME"
    /// "wrapper-a.eml")`, which `parseSinglePart` uses as the filename fallback.
    /// So the assertions below discriminate two ways: the disposition filename
    /// must win over the `name` parameter, and `dispositionType` must be
    /// `attachment` rather than whatever the nested part list starts with.
    @Test("a message/rfc822 part's disposition is read at index 11, keeping its filename")
    func messageRFC822DispositionOffset() throws {
        let response = try #require(
            try IMAPFetchWire.parsed("imap-fetch-bodystructure-message").first)
        let structure = try #require(response.bodyStructure)
        #expect(structure.mimeType == "multipart/mixed")
        #expect(structure.children.map(\.mimeType) == ["text/plain", "message/rfc822"])

        let forwarded = try #require(structure.children.last)
        #expect(forwarded.partNumber == "2")
        #expect(forwarded.dispositionType == "attachment")
        #expect(forwarded.filename == "forwarded-a.eml")
        // Not "wrapper-a.eml": the disposition filename outranks the fallback.
        #expect(forwarded.parameters["name"] == "wrapper-a.eml")
        // The nested message stays opaque — its own text/plain is NOT decomposed
        // into a child, so it cannot be mistaken for the message's body part.
        #expect(forwarded.children.isEmpty)
        #expect(structure.plainTextPart?.partNumber == "1")

        // Compared as a whole collection, so a wrong count cannot be masked.
        #expect(structure.attachments == [
            MailAttachment(attachmentID: "2", filename: "forwarded-a.eml",
                           mimeType: "message/rfc822", size: 420),
        ])
        let message = IMAPFetchParser.message(response, id: "u205", threadID: "t205")
        #expect(message.hasAttachments)
        #expect(message.attachments == structure.attachments)
    }

    /// The other side of the same discriminator, and the reason it has to include
    /// the SUBTYPE. RFC 3501's `media-message` is `"MESSAGE" SP "RFC822"` and
    /// nothing else, so only that subtype is a `body-type-msg` with its
    /// disposition at index 11. `message/delivery-status` is a `body-type-basic`
    /// — DSP at index 8 — and it is what a bounce notification is made of, so
    /// this is not a hypothetical shape.
    ///
    /// Switching on the type alone reproduces the original bug one subtype over:
    /// index 11 does not exist in this part, so the disposition reads as absent
    /// and the filename falls through to the Content-Type `name`. That is the
    /// dangerous failure, not a loud one — the attachment is still listed, under
    /// a plausible wrong name (`report-a.txt`), which is why the fixture carries
    /// a `name` that differs from the disposition `filename`.
    @Test("a message/delivery-status part reads its disposition from index 8, not 11")
    func nonRFC822MessageSubtypeUsesBasicOffset() throws {
        let wire = "* 1 FETCH (UID 213 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 8 1)"
            + "(\"MESSAGE\" \"DELIVERY-STATUS\" (\"NAME\" \"report-a.txt\") NIL NIL "
            + "\"7BIT\" 300 NIL "
            + "(\"ATTACHMENT\" (\"FILENAME\" \"delivery-status-a.txt\")) NIL NIL) "
            + "\"REPORT\" (\"BOUNDARY\" \"b11\")))\r\n"
        let response = try IMAPFetchWire.parsedLine(wire)
        let structure = try #require(response.bodyStructure)
        #expect(structure.mimeType == "multipart/report")
        #expect(structure.children.map(\.mimeType)
            == ["text/plain", "message/delivery-status"])

        let report = try #require(structure.children.last)
        #expect(report.dispositionType == "attachment")
        #expect(report.filename == "delivery-status-a.txt")
        // Not "report-a.txt": the disposition at index 8 was found, so the
        // Content-Type `name` fallback was never reached.
        #expect(report.parameters["name"] == "report-a.txt")
        #expect(structure.attachments == [
            MailAttachment(attachmentID: "2", filename: "delivery-status-a.txt",
                           mimeType: "message/delivery-status", size: 300),
        ])
    }

    // MARK: - Refusing a malformed child

    /// A child part list that will not parse must fail the whole structure.
    ///
    /// `break`ing out of the child loop instead loses that child AND every
    /// sibling after it, and leaves the loop index pointing at a part LIST — so
    /// the subtype read that follows lands on the list, `stringValue` is `nil`,
    /// and the parser returns a confidently wrong `multipart/` container with a
    /// truncated child set. A structure a session can log and fail on beats a
    /// body tree that looks plausible.
    ///
    /// `(NIL "PDF")` is the malformed child: its first element is neither a list
    /// (so it is not read as a nested multipart) nor a string (so
    /// `parseSinglePart` cannot name a type). The valid `text/plain` sibling in
    /// front of it is what makes the pre-fix code return rather than trip the
    /// "multipart with no parts" guard.
    @Test("a multipart whose child will not parse throws instead of truncating siblings")
    func malformedChildThrows() throws {
        let wire = "* 1 FETCH (UID 208 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 8 1)"
            + "(NIL \"PDF\") \"MIXED\" (\"BOUNDARY\" \"b9\")))\r\n"
        let response = try IMAPFetchWire.line(wire)

        let thrown = #expect(throws: IMAPFetchParseError.self) {
            _ = try IMAPFetchParser.parse(response)
        }
        guard case .malformedBodyStructure(let reason) = try #require(thrown) else {
            Issue.record("expected .malformedBodyStructure, got \(String(describing: thrown))")
            return
        }
        #expect(reason.isEmpty == false)
    }

    /// The neighbouring refusal, kept alongside it: an *empty* nested part list
    /// is malformed for the same reason and by the same guard.
    @Test("an empty nested part list is malformed, not an empty child")
    func emptyNestedPartListThrows() throws {
        let wire = "* 1 FETCH (UID 209 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 8 1)"
            + "() \"MIXED\" (\"BOUNDARY\" \"b9\")))\r\n"
        let response = try IMAPFetchWire.line(wire)
        let thrown = #expect(throws: IMAPFetchParseError.self) {
            _ = try IMAPFetchParser.parse(response)
        }
        guard case .malformedBodyStructure = try #require(thrown) else {
            Issue.record("expected .malformedBodyStructure, got \(String(describing: thrown))")
            return
        }
    }

    // MARK: - The whole-body fallback gate

    /// `BODY[TEXT]` means "the entire MIME body", which equals part 1's bytes
    /// ONLY for a single-part message. For a multipart it is boundary delimiters
    /// and per-part headers as well, so letting part 1 fall back to it puts raw
    /// MIME into `MessageBody.plainText` — the bug `allowsWholeBodyFallback`
    /// closes.
    ///
    /// The response below is the realistic shape: a server that was asked for
    /// `BODY[TEXT]` and a `BODYSTRUCTURE`, with no per-part section fetched.
    /// Nothing is a substitute for part 1, so the correct answer is *no* body
    /// text — an empty `plainText` the caller can then fill by fetching `BODY[1]`.
    @Test("a multipart does not fall back to BODY[TEXT] for part 1")
    func multipartDoesNotUseWholeBodyFallback() throws {
        let raw = "--b10\r\nContent-Type: text/plain\r\n\r\nBody one\r\n"
            + "--b10\r\nContent-Type: text/html\r\n\r\n<p>Body one</p>\r\n--b10--\r\n"
        let wire = "* 1 FETCH (UID 210 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 8 1)"
            + "(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 15 1) "
            + "\"ALTERNATIVE\" (\"BOUNDARY\" \"b10\")) "
            + "BODY[TEXT] {\(raw.utf8.count)}\r\n\(raw))\r\n"
        let response = try IMAPFetchWire.parsedLine(wire)

        // The preconditions of the bug really are present: a multipart structure,
        // a part 1 whose bytes were NOT fetched, and a TEXT section that was.
        let structure = try #require(response.bodyStructure)
        #expect(structure.children.isEmpty == false)
        #expect(structure.plainTextPart?.partNumber == "1")
        #expect(response.sections["1"] == nil)
        #expect(response.sections["TEXT"] == Data(raw.utf8))

        let body = IMAPFetchParser.body(response, messageID: "u210")
        #expect(body.plainText == "")
        #expect(body.html == nil)
        // Spelled out, because "" is only correct incidentally: what must never
        // reach a plainText surface is the MIME framing.
        #expect(body.plainText.contains("--b10") == false)
        #expect(body.plainText.contains("Content-Type") == false)
    }

    /// The other half of the gate: it must not have simply disabled a path that
    /// worked. A single-part message is normally fetched as `BODY[TEXT]` — the
    /// part number `1` never appears in that response at all — so part 1 reading
    /// those keys is the ONLY way it gets any text.
    @Test("a single part still falls back to BODY[TEXT] for part 1")
    func singlePartStillUsesWholeBodyFallback() throws {
        let raw = "Body one"
        let wire = "* 1 FETCH (UID 211 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(raw.utf8.count) 1) "
            + "BODY[TEXT] {\(raw.utf8.count)}\r\n\(raw))\r\n"
        let response = try IMAPFetchWire.parsedLine(wire)
        let structure = try #require(response.bodyStructure)
        #expect(structure.children.isEmpty)
        #expect(structure.partNumber == "1")
        #expect(response.sections["1"] == nil)

        let body = IMAPFetchParser.body(response, messageID: "u211")
        #expect(body.plainText == "Body one")
    }

    /// And the `BODY[]` spelling of the same fallback, which the gate covers too.
    @Test("a single part falls back to BODY[] as well as BODY[TEXT]")
    func singlePartFallsBackToWholeBodyKey() throws {
        let raw = "Body one"
        let wire = "* 1 FETCH (UID 212 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" "
            + "(\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(raw.utf8.count) 1) "
            + "BODY[] {\(raw.utf8.count)}\r\n\(raw))\r\n"
        let response = try IMAPFetchWire.parsedLine(wire)
        #expect(response.sections[""] == Data(raw.utf8))
        let body = IMAPFetchParser.body(response, messageID: "u212")
        #expect(body.plainText == "Body one")
    }
}
