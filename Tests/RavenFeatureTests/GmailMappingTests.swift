import Testing
import Foundation
@testable import RavenFeature

@Suite("Gmail mapping")
struct GmailMappingTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test("a thread response maps to a MailThread with messages oldest-first")
    func mapsThread() throws {
        let wire = try JSONDecoder().decode(GmailThreadDTO.self, from: fixture("thread-0"))
        let thread = GmailMapping.thread(wire, accountID: "a1")
        #expect(thread.id == wire.id)
        #expect(thread.messages.isEmpty == false)
        #expect(thread.messages == thread.messages.sorted { $0.date < $1.date })
    }

    // `thread-0.json` and `thread-1.json` are both single-message captures —
    // the assertion above would pass against ANY ordering (including no sort
    // at all), so it is not a real test of the sort. `thread-multi.json` has
    // two messages with distinct `internalDate`s (see that file's
    // `_fixtureNote` for how it was produced) specifically so this test can
    // fail if the sort is ever removed or broken.
    @Test("a multi-message thread's messages are sorted oldest-first even when the wire order is reversed")
    func mapsMultiMessageThreadOrdering() throws {
        let wire = try JSONDecoder().decode(GmailThreadDTO.self, from: fixture("thread-multi"))
        #expect((wire.messages?.count ?? 0) == 2)

        // The fixture already arrives newest-first on the wire; map it as-is.
        let thread = GmailMapping.thread(wire, accountID: "a1")
        #expect(thread.messages.map(\.id) == ["19fc00000000m001", "19fc00000000m002"])
        #expect(thread.messages[0].date < thread.messages[1].date)

        // Deliberately hand the mapper the messages in the OPPOSITE order
        // from the fixture (i.e. oldest-first on the wire this time) to prove
        // the sort is real and not an accident of the fixture's own order.
        let reversedDTO = GmailThreadDTO(id: wire.id, historyId: wire.historyId,
                                        messages: Array((wire.messages ?? []).reversed()))
        let reorderedThread = GmailMapping.thread(reversedDTO, accountID: "a1")
        #expect(reorderedThread.messages.map(\.id) == ["19fc00000000m001", "19fc00000000m002"])
    }

    @Test("UNREAD in labelIds becomes isRead == false")
    func mapsUnread() {
        let message = GmailMapping.message(
            GmailMessageDTO(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"],
                            snippet: "hi", internalDate: "1772000000000",
                            payload: .init(headers: [.init(name: "From", value: "b@x.com"),
                                                     .init(name: "Subject", value: "S")],
                                           mimeType: "text/plain", body: nil, parts: nil)))
        #expect(message.isRead == false)
        #expect(message.labelIDs.contains("INBOX"))
    }

    @Test("internalDate milliseconds become a Date, not a 1970 timestamp")
    func mapsDate() {
        let message = GmailMapping.message(
            GmailMessageDTO(id: "m1", threadId: "t1", labelIds: [], snippet: "",
                            internalDate: "1772000000000",
                            payload: .init(headers: [], mimeType: "text/plain",
                                           body: nil, parts: nil)))
        #expect(message.date == Date(timeIntervalSince1970: 1_772_000_000))
    }

    @Test("a base64url body decodes, including - and _ substitutions")
    func decodesBody() {
        let encoded = "SGVsbG8sIHdvcmxkPw"   // "Hello, world?"
        #expect(GmailMapping.decodeBase64URL(encoded) == "Hello, world?")
    }

    @Test("body prefers text/plain over text/html on a multipart message")
    func bodyPrefersPlainText() throws {
        let dto = try JSONDecoder().decode(GmailMessageDTO.self, from: fixture("message-0"))
        let body = GmailMapping.body(dto)
        #expect(body.plainText.contains("Repository: someoneorg/example-repo"))
        #expect(body.html != nil)
    }

    @Test("body falls back to sanitized HTML when there is no text/plain part")
    func bodyFallsBackToSanitizedHTML() {
        let htmlOnly = GmailMessageDTO(
            id: "m1", threadId: "t1", labelIds: [], snippet: "",
            internalDate: "1772000000000",
            payload: .init(headers: [], mimeType: "text/html",
                           body: .init(data: GmailMapping.base64URL("<p>Hi <b>there</b></p>"),
                                       size: nil),
                           parts: nil))
        let body = GmailMapping.body(htmlOnly)
        #expect(body.html == "<p>Hi <b>there</b></p>")
        #expect(body.plainText.contains("Hi there"))
        #expect(body.plainText.contains("<") == false)
    }
}
