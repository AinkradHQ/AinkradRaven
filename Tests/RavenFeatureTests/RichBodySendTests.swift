import Testing
import Foundation
@testable import RavenFeature

/// Task 21: what a rich body becomes on the wire.
///
/// The renderer's own output is pinned next door in `RichBodyHTMLTests`; this
/// file is about the MIME envelope around it — the nesting, the charset and
/// transfer encoding on both parts, the signature, the two providers agreeing,
/// and the at-most-once semantics holding with a formatted message in the
/// queue.
@Suite("Rich body on the wire")
struct RichBodyMIMETests {
    private let to = MailAddress(email: "b@example.test", name: "Bee")

    private func rich(_ text: String, _ spans: [RichBody.Span] = []) -> RichBody {
        RichBody(text: text, spans: spans)
    }

    private func build(_ message: OutgoingMessage) -> String {
        RFC822Builder.message(message, includeBccHeader: true, identityLookup: { _ in nil })
    }

    // MARK: - Structure

    @Test("a rich message is multipart/alternative: plain from the body, html rendered from it")
    func alternativeCarriesBothParts() throws {
        let body = rich("Hello there", [RichBody.Span(start: 0, length: 5, kind: .bold)])
        let raw = build(OutgoingMessage(to: [to], subject: "Subject 1",
                                        bodyText: body.text, richBody: body))

        // Whole-collection equality, so nothing can sit between the two parts
        // and neither can be missing.
        #expect(MIMEProbe.contentTypes(raw) == ["multipart/alternative",
                                                "text/plain; charset=UTF-8",
                                                "text/html; charset=UTF-8"])
        #expect(MIMEProbe.transferEncodings(raw) == ["base64", "base64"])
        // The plain part is the IDENTITY FUNCTION on the rich body's text — not
        // re-derived from the HTML, and not a stub.
        #expect(MIMEProbe.decodedParts(raw) == ["Hello there",
                                                "<p><strong>Hello</strong> there</p>"])
    }

    @Test("with an attachment the alternative nests inside one multipart/mixed")
    func attachmentsWrapTheAlternative() throws {
        let body = rich("Hello there", [RichBody.Span(start: 0, length: 5, kind: .bold)])
        let raw = build(OutgoingMessage(
            to: [to], subject: "Subject 1", bodyText: body.text,
            attachments: [OutgoingAttachment(filename: "a.pdf", mimeType: "application/pdf",
                                             data: Data("bytes".utf8))],
            richBody: body))

        #expect(MIMEProbe.contentTypes(raw) == ["multipart/mixed",
                                                "multipart/alternative",
                                                "text/plain; charset=UTF-8",
                                                "text/html; charset=UTF-8",
                                                "application/pdf; name=\"a.pdf\""])
        // Exactly the nesting the extraction preserved: two boundaries, and the
        // alternative's own boundary opens INSIDE the mixed one rather than
        // beside it.
        let boundaries = MIMEProbe.boundaryTokens(raw)
        #expect(Set(boundaries).count == 2)
        let outer = try #require(boundaries.first)
        let inner = try #require(boundaries.first { $0 != outer })
        let outerStart = try #require(raw.range(of: "--\(outer)"))
        let innerStart = try #require(raw.range(of: "--\(inner)"))
        #expect(outerStart.lowerBound < innerStart.lowerBound)
        #expect(raw.contains("--\(inner)--\r\n\r\n--\(outer)\r\n"
                             + "Content-Type: application/pdf; name=\"a.pdf\""),
                "the alternative must close before the attachment part opens")
    }

    /// The `nil` case is the one this task must not have touched. Asserted
    /// against a LITERAL, not against `MarkdownToHTML.renderComposed` — an
    /// expectation computed by calling the code it checks would pass however
    /// the renderer choice was wired.
    @Test("a message with no rich body still renders through the Markdown path")
    func plainMessagesAreUnchanged() {
        let raw = build(OutgoingMessage(to: [to], subject: "Subject 1",
                                        bodyText: "- one\n- two"))
        // CRLF in the expectation because RFC 2046 requires it of a `text/*`
        // part and `MIMEHeader.base64Body` has always canonicalised to it —
        // pre-existing behaviour this task did not touch.
        #expect(MIMEProbe.decodedParts(raw) == ["- one\r\n- two",
                                                "<ul><li>one</li><li>two</li></ul>"])
    }

    /// The identity function, on a body whose whitespace is load-bearing.
    ///
    /// Every other rich fixture in this file is whitespace-clean, so none of
    /// them can tell the identity function apart from a lossy derivation — a
    /// `.trimmingCharacters(in: .whitespacesAndNewlines)` on the plain part
    /// leaves them all green. This one cannot be satisfied that way, and the
    /// shape is not contrived: it is exactly what `ReplyComposer` produces, and
    /// exactly what `spansSurviveTheQuoteTrim` renders next door.
    ///
    /// What a trim would actually cost: the HTML part rebases its spans off the
    /// UNTRIMMED string, so trimming only the plain part desynchronises the two
    /// halves of one message about where the text begins — silently, with both
    /// parts individually well-formed.
    @Test("the plain part is the identity function, leading newline and all")
    func plainPartIsNotTrimmed() throws {
        let text = "\nMy reply\n\nOn Mon, A wrote:\n> original"
        let body = rich(text, [RichBody.Span(start: 1, length: 2, kind: .bold)])
        let raw = build(OutgoingMessage(to: [to], subject: "Subject 1",
                                        bodyText: text, richBody: body))

        // The CRLF canonicalisation is applied by hand to the EXPECTATION, so
        // the comparison is against a literal rather than against the transform
        // re-run on the actual.
        let expected = "\r\nMy reply\r\n\r\nOn Mon, A wrote:\r\n> original"
        let plainBytes = try #require(MIMEProbe.decodedPartData(raw).first)
        #expect(Array(plainBytes) == Array(Data(expected.utf8)))
        // Both halves of the same message, from the same untrimmed string: the
        // bold run still lands on "My", which is only true at offset 1.
        #expect(MIMEProbe.decodedParts(raw).last
            == "<p><strong>My</strong> reply</p>"
                + "<p>On Mon, A wrote:</p>"
                + "<blockquote>original</blockquote>")
    }

    // MARK: - Non-ASCII

    @Test("a non-ASCII body decodes back byte-identically, under a 2047 subject")
    func nonASCIISurvives() throws {
        // Arabic (RTL, multi-byte) and an emoji outside the BMP — a surrogate
        // pair, which is where a UTF-16 offset mistake shows up. Deliberately
        // ONE line: `MIMEHeader.base64Body` canonicalises line endings to CRLF
        // as RFC 2046 requires of a `text/*` part, so a multi-line body could
        // only be compared against a re-canonicalised expectation, and
        // "byte-identical" would quietly become "identical after we applied the
        // same transform twice".
        // Predominantly Arabic, so `BaseTextDirection.detect` also has to reach
        // `rtl` here and the `dir` wrapper below is a real assertion rather
        // than a decoration.
        let text = "مرحبا 🌍 سلام café"
        let body = rich(text, [RichBody.Span(start: 0, length: 5, kind: .bold),
                               RichBody.Span(start: 6, length: 2, kind: .italic)])
        let raw = build(OutgoingMessage(to: [to], subject: "مرحبا 🌍",
                                        bodyText: text, richBody: body))

        // The subject is an RFC 2047 encoded word, and the raw non-ASCII never
        // appears in a header.
        let subjectLine = try #require(
            raw.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject: ") })
        #expect(subjectLine.hasPrefix("Subject: =?UTF-8?B?"))
        #expect(subjectLine.contains("مرحبا") == false)
        #expect(RFC2047.decode(String(subjectLine.dropFirst("Subject: ".count))) == "مرحبا 🌍")

        // Both parts declare the charset AND the transfer encoding — a charset
        // with no encoding is how raw UTF-8 goes out under an implicit 7bit.
        #expect(MIMEProbe.contentTypes(raw) == ["multipart/alternative",
                                                "text/plain; charset=UTF-8",
                                                "text/html; charset=UTF-8"])
        #expect(MIMEProbe.transferEncodings(raw) == ["base64", "base64"])

        // Byte-identical, compared as BYTES rather than as `String`s, so a
        // normalisation change would not be able to hide behind Unicode
        // equivalence.
        let plainBytes = try #require(MIMEProbe.decodedPartData(raw).first)
        #expect(Array(plainBytes) == Array(Data(text.utf8)))
        // The emoji span is two UTF-16 code units for one character: a renderer
        // slicing by `Character` would wrap the wrong run here.
        #expect(MIMEProbe.decodedParts(raw).last
            == "<div dir=\"rtl\"><p><strong>مرحبا</strong> <em>🌍</em> سلام café</p></div>")
    }

    // MARK: - Provider parity

    /// Both providers, one body. The bytes must agree everywhere EXCEPT the
    /// `Bcc` header, whose two policies are deliberately opposite: Gmail derives
    /// the envelope from the headers and must transmit it, SMTP names blind
    /// recipients in `RCPT TO` and must not. Asserting the body match without
    /// also asserting that asymmetry would pass for a build that had quietly
    /// unified them and started leaking blind recipients.
    @Test("GmailProvider and SMTPSubmitter produce the same body structure")
    func providersAgreeOnBodyStructure() async throws {
        let body = rich("Hello there", [RichBody.Span(start: 0, length: 5, kind: .bold)])
        let message = OutgoingMessage(
            to: [to], cc: [MailAddress(email: "c@example.test")],
            bcc: [MailAddress(email: "blind@example.test")],
            subject: "Subject 1", bodyText: body.text,
            attachments: [OutgoingAttachment(filename: "a.pdf", mimeType: "application/pdf",
                                             data: Data("bytes".utf8))],
            richBody: body)

        let gmail = try #require(GmailMapping.decodeBase64URL(
            GmailProvider.rfc822(message, identityLookup: { _ in nil })))
        let submitter = await SMTPHarness.submitter(SMTPHarness.transport(),
                                                    endpoint: SMTPHarness.implicitEndpoint)
        let smtp = submitter.messageData(for: message)

        // The Bcc asymmetry, both halves.
        #expect(gmail.contains("\r\nBcc: blind@example.test\r\n"))
        #expect(smtp.lowercased().contains("bcc:") == false)
        #expect(smtp.contains("blind@example.test") == false)

        // The body structure, as the ordered list of parts...
        let expected = ["multipart/mixed", "multipart/alternative",
                        "text/plain; charset=UTF-8", "text/html; charset=UTF-8",
                        "application/pdf; name=\"a.pdf\""]
        #expect(MIMEProbe.contentTypes(gmail) == expected)
        #expect(MIMEProbe.contentTypes(smtp) == expected)
        #expect(MIMEProbe.decodedParts(gmail) == ["Hello there",
                                                  "<p><strong>Hello</strong> there</p>"])
        #expect(MIMEProbe.decodedParts(smtp) == MIMEProbe.decodedParts(gmail))

        // ...and then byte-for-byte, boundaries normalised, with the one header
        // that is allowed to differ removed. Nothing else may.
        #expect(MIMEProbe.normalisedBoundaries(gmail)
            .replacingOccurrences(of: "Bcc: blind@example.test\r\n", with: "")
            == MIMEProbe.normalisedBoundaries(smtp))
    }

    // MARK: - Forward compatibility

    /// A literal document in the shape written before this task: no `richBody`
    /// key at all. Written by hand rather than by re-encoding a current
    /// `OutgoingMessage`, because a fixture produced by today's encoder cannot
    /// distinguish "old documents decode" from "today's encoder round-trips".
    @Test("an OutgoingMessage written before this task decodes without throwing")
    func preTaskDocumentsDecode() throws {
        let json = """
        {"to":[{"email":"b@example.test","name":"Bee"}],"cc":[],"bcc":[],
         "subject":"Subject 1","bodyText":"Hello there","attachments":[]}
        """
        let message = try JSONDecoder().decode(OutgoingMessage.self, from: Data(json.utf8))

        #expect(message.bodyText == "Hello there")
        #expect(message.richBody == nil)
        // And it still sends — through the Markdown path, unchanged.
        #expect(MIMEProbe.decodedParts(build(message)) == ["Hello there",
                                                           "<p>Hello there</p>"])
    }
}

/// The signature is appended in exactly one place (`SendAttempt`) and rendered
/// in two (the plain part verbatim, the HTML part inside `<div class="sig">`).
/// "Once, to both parts, and not twice" is the property, and it is asserted end
/// to end — from the Send button's entry point out to the transmitted bytes —
/// because a second append could be introduced anywhere between them.
@Suite("Rich body and the account signature")
@MainActor struct RichBodySignatureOnTheWireTests {
    @Test("the account signature appends once, to both parts, and not twice")
    func signatureAppendsOnce() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "a@example.test", displayName: "A",
                                          signature: "Sincerely,\nAda"))
        let body = RichBody(text: "Hello there",
                            spans: [RichBody.Span(start: 0, length: 5, kind: .bold)])
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.test")],
                                      subject: "Subject 1", bodyText: body.text,
                                      accountID: "a1", richBody: body)

        _ = try await SendAttempt.send(message, draftID: nil, outbox: outbox,
                                       store: store, drain: outbox.drain)

        let sent = try #require(provider.sentMessages.first)
        let raw = RFC822Builder.message(sent, includeBccHeader: true,
                                        identityLookup: { _ in nil })
        let parts = MIMEProbe.decodedParts(raw)
        #expect(parts == ["Hello there\r\n-- \r\nSincerely,\r\nAda",
                          "<p><strong>Hello</strong> there</p>"
                              + "<div class=\"sig\">-- <br>Sincerely,<br>Ada</div>"])
        // Stated as counts too, so a doubled append that happened to produce a
        // still-plausible string could not slip past the equality above.
        #expect(parts.allSatisfy { $0.components(separatedBy: "Sincerely,").count - 1 == 1 })
        #expect(parts[0].components(separatedBy: "-- ").count - 1 == 1)
        #expect(parts[1].components(separatedBy: "class=\"sig\"").count - 1 == 1)
    }
}

/// At-most-once, re-asserted with a formatted message in the queue.
///
/// Success is RECORDED, never inferred from an entry's absence. Adding a field
/// to `OutgoingMessage` is exactly the kind of change that can make an entry
/// undecodable, and an entry that fails to load is an entry whose fate is no
/// longer recorded anywhere — so the semantics are driven again here rather
/// than assumed to be covered by `SendAttemptTests`, which uses a plain body.
@Suite("At-most-once with a rich body")
@MainActor struct RichBodyAtMostOnceTests {
    private func richMessage() -> OutgoingMessage {
        let body = RichBody(text: "Hello there",
                            spans: [RichBody.Span(start: 0, length: 5, kind: .bold)])
        return OutgoingMessage(to: [MailAddress(email: "b@example.test")],
                               subject: "Subject 1", bodyText: body.text,
                               accountID: "a1", richBody: body)
    }

    @Test("enqueue, provider failure, retry, dead-letter — and the draft survives")
    func deadLetteredRichSendKeepsTheDraft() async throws {
        let provider = FakeMailProvider()
        // Two scripted failures against `maxAttempts: 2`, so the entry really is
        // retried before it is given up on rather than dead-lettered on the
        // first refusal.
        provider.failures["send"] = [MailError.providerFailed(status: 500, message: "boom"),
                                     MailError.providerFailed(status: 500, message: "boom")]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            maxAttempts: 2, accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(richMessage())
        defer { DraftBox.shared.remove(draftID) }

        let first = try await SendAttempt.send(richMessage(), draftID: draftID, outbox: outbox,
                                               store: store, drain: outbox.drain)
        #expect(first.outcome == OutboxSendOutcome.queued(inFlight: false))
        #expect(DraftBox.shared.draft(draftID) != nil)

        // The retry. `outcome(for:)` must still be reading a RECORD, not the
        // absence of one.
        await outbox.drain()
        guard case .deadLettered(let lastError) = outbox.outcome(for: first.entryID) else {
            Issue.record("the retried entry was not dead-lettered")
            return
        }
        #expect(lastError?.contains("boom") == true)
        #expect(provider.sentMessages.isEmpty)
        #expect(DraftBox.shared.draft(draftID) != nil,
                "a dead-lettered send must not destroy the user's draft")
        // The formatting is still on the dead-lettered entry, so resolving it in
        // Accounts resends the message the user actually composed.
        guard case .send(let held) = outbox.deadLettered().first?.operation else {
            Issue.record("the dead-lettered entry did not survive with its operation")
            return
        }
        #expect(held.richBody?.spans.map(\.kind) == [RichBody.Kind.bold])
        #expect(held.richBody?.text == held.bodyText)
    }

    @Test("a rich send removed before it went out reports that, and preserves the draft")
    func removedWithoutSendingPreservesTheDraft() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let draftID = try DraftBox.shared.save(richMessage())
        defer { DraftBox.shared.remove(draftID) }
        let entryID = try outbox.enqueue(.send(richMessage()), accountID: "a1",
                                         holdUntil: nil, sendAt: nil, draftID: draftID)

        try outbox.discard(entryID)

        // Absence is NOT success: the entry is gone and the outcome still says
        // nothing was transmitted.
        #expect(outbox.outcome(for: entryID) == .removedWithoutSending)
        #expect(provider.sentMessages.isEmpty)
        #expect(DraftBox.shared.draft(draftID) != nil,
                "a discarded send must not destroy the user's draft")
        #expect(SendAttempt.describe(.removedWithoutSending, draftID: draftID)
            .contains("Nothing was transmitted"))
    }
}
