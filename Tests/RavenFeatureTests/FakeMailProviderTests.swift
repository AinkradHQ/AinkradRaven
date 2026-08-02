import Testing
import Foundation
@testable import RavenFeature

@Suite("FakeMailProvider")
struct FakeMailProviderTests {
    @Test("a scripted failure throws once and then succeeds")
    func scriptedFailure() async throws {
        let provider = FakeMailProvider()
        provider.failures["fetchLabels"] = [MailError.rateLimited(retryAfter: 1)]
        provider.labelList = [MailLabel(id: "INBOX", name: "Inbox", kind: .system)]

        await #expect(throws: MailError.self) { try await provider.fetchLabels() }
        let labels = try await provider.fetchLabels()
        #expect(labels.map(\.id) == ["INBOX"])
    }
}
