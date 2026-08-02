import Testing
import Foundation
@testable import MailFeature

@Suite("Model coding")
struct ModelCodingTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    @Test("a thread summary survives a JSON round trip")
    func summaryRoundTrip() throws {
        let summary = ThreadSummary(
            id: "t1", accountID: "a1", subject: "Invoice",
            participants: [MailAddress(email: "b@x.com", name: "Bea")],
            lastMessageDate: Date(timeIntervalSince1970: 1_700_000_000),
            messageCount: 2, unreadCount: 1, isStarred: false,
            labelIDs: ["INBOX"], snippet: "Attached is…")
        #expect(try roundTrip(summary) == summary)
    }

    @Test("an address parses a display-name form")
    func addressParsing() {
        let parsed = MailAddress(rfc5322: "Bea Smith <b@x.com>")
        #expect(parsed?.email == "b@x.com")
        #expect(parsed?.name == "Bea Smith")
    }

    @Test("an address parses a bare-email form")
    func bareAddress() {
        let parsed = MailAddress(rfc5322: "b@x.com")
        #expect(parsed?.email == "b@x.com")
        #expect(parsed?.name == nil)
    }

    @Test("an address rejects a string with no @")
    func rejectsNonAddress() {
        #expect(MailAddress(rfc5322: "not an address") == nil)
    }
}
