import Testing
import Foundation
@testable import RavenFeature

/// Bcc, end to end: the model, the RFC822 builder, the compose stamp, the
/// signature rebuild, and the persistence round trip.
@Suite("Bcc end to end")
struct BccTests {
    private let bea = MailAddress(email: "bea@x.com", name: "Bea Smith")
    private let blind = MailAddress(email: "boss@y.com")

    @Test("the model carries bcc and defaults it to empty")
    func modelDefault() {
        let message = OutgoingMessage(to: [bea], subject: "S", bodyText: "B")
        #expect(message.bcc.isEmpty)
        #expect(OutgoingMessage(to: [bea], bcc: [blind], subject: "S", bodyText: "B").bcc
            == [blind])
    }

    @Test("a Bcc header IS emitted into the raw message uploaded to Gmail")
    func rawCarriesBccHeader() {
        // The header must be present in what we upload. `messages/send` with
        // `raw` offers no separate envelope: Gmail builds the envelope from the
        // headers and then strips `Bcc` before delivery. Omitting it here — the
        // instinctive reading of "Bcc must not appear in the transmitted
        // headers" — silently drops the blind recipient entirely.
        let message = OutgoingMessage(to: [bea], bcc: [blind], subject: "S", bodyText: "B")
        let raw = decoded(GmailProvider.rfc822(message, identityLookup: { _ in nil }))
        #expect(raw.contains("\r\nBcc: boss@y.com\r\n"))
    }

    @Test("no Bcc header appears when there are no blind recipients")
    func noHeaderWhenEmpty() {
        // Byte-for-byte unchanged for every message that predates this.
        let message = OutgoingMessage(to: [bea], cc: [MailAddress(email: "cal@x.com")],
                                      subject: "S", bodyText: "B")
        let raw = decoded(GmailProvider.rfc822(message, identityLookup: { _ in nil }))
        #expect(!raw.lowercased().contains("bcc:"))
        #expect(raw.contains("\r\nCc: cal@x.com\r\n"))
    }

    @Test("a Bcc display name is sanitized and encoded like every other header")
    func bccHeaderIsSanitized() {
        // The injection vector `MIMEHeader` exists to close was literally "a
        // header value that smuggles in a Bcc:". The Bcc line itself must not be
        // the one line that formats its own string.
        let hostile = MailAddress(email: "boss@y.com", name: "Boss\r\nBcc: evil@z.com")
        let raw = decoded(GmailProvider.rfc822(
            OutgoingMessage(to: [bea], bcc: [hostile], subject: "S", bodyText: "B"),
            identityLookup: { _ in nil }))
        #expect(!raw.contains("evil@z.com\r\n"))
        // Exactly one Bcc header line, not two.
        #expect(raw.components(separatedBy: "\r\nBcc: ").count == 2)
    }

    @Test("the compose stamp preserves bcc for a reply")
    func stampPreservesBcc() {
        let context = ComposeContext.reply(mode: .reply, thread: ComposeThreadReference(
            threadID: "t1", accountID: "acct", lastMessageRFC822ID: "<m1@x>"))
        let stamped = context.stamp(
            OutgoingMessage(to: [bea], bcc: [blind], subject: "S", bodyText: "B"),
            fallbackAccountID: nil)
        #expect(stamped.bcc == [blind])
        #expect(stamped.threadID == "t1")
    }

    @Test("attributing a message to an account preserves bcc")
    func attributedPreservesBcc() {
        let message = OutgoingMessage(to: [bea], bcc: [blind], subject: "S", bodyText: "B")
        #expect(message.attributed(to: "acct").bcc == [blind])
    }

    @Test("bcc survives the draft/outbox persistence round trip")
    func codingRoundTrip() throws {
        let message = OutgoingMessage(to: [bea], cc: [], bcc: [blind], subject: "S",
                                      bodyText: "B", accountID: "acct")
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(OutgoingMessage.self, from: data) == message)
    }

    @Test("a message persisted before bcc existed still decodes")
    func legacyDecode() throws {
        // An outbox entry queued by an earlier build must not fail to load.
        let json = """
        {"to":[{"email":"bea@x.com"}],"subject":"S","bodyText":"B"}
        """
        let message = try JSONDecoder().decode(OutgoingMessage.self,
                                               from: Data(json.utf8))
        #expect(message.bcc.isEmpty)
        #expect(message.to.first?.email == "bea@x.com")
    }

    @Test("the MCP create_draft tool declares bcc")
    func mcpSchemaDeclaresBcc() {
        let tool = RavenMCPServer.tools.first { $0.name == "create_draft" }
        #expect(tool?.schemaJSON.contains("\"bcc\"") == true)
    }

    /// Gmail's `raw` field is base64url; decode it back so assertions are about
    /// the actual header bytes rather than an encoding.
    private func decoded(_ raw: String) -> String {
        var base64 = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Signature rebuild carries every field")
@MainActor struct SignatureRebuildTests {
    @Test("appending a signature does not drop bcc, attachments or the ICS reply")
    func nothingIsDropped() async throws {
        // This rebuild used to omit `attachments` and `icsReply`, so signing a
        // message SILENTLY DROPPED its attachments — for every account with a
        // non-empty signature, which is the normal configuration. `withSignature`
        // is private, so the behaviour is pinned through the real send path and
        // asserted on what the provider actually received.
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a@x.com",
                                          displayName: "A", signature: "Best,\nA"))
        let message = OutgoingMessage(
            to: [MailAddress(email: "bea@x.com")],
            bcc: [MailAddress(email: "boss@y.com")],
            subject: "S", bodyText: "Body", accountID: "a1",
            attachments: [OutgoingAttachment(filename: "a.txt", mimeType: "text/plain",
                                             data: Data("hi".utf8))],
            icsReply: ICSReply(icsText: "BEGIN:VCALENDAR\nEND:VCALENDAR"))

        _ = try await SendAttempt.send(message, draftID: nil, outbox: outbox,
                                       store: store, drain: outbox.drain)

        let sent = provider.sentMessages.first
        #expect(sent?.bodyText == "Body\n-- \nBest,\nA")
        #expect(sent?.bcc.map(\.email) == ["boss@y.com"])
        #expect(sent?.attachments.count == 1)
        #expect(sent?.icsReply != nil)
    }
}
