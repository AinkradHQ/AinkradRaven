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

    @Test("searchThreads returns canned results honoring the limit")
    func searchThreadsReturnsCannedResults() async throws {
        let provider = FakeMailProvider()
        provider.searchResults = (0..<5).map { index in
            MailThread(id: "t\(index)", accountID: "a1", messages: [
                MailMessage(id: "m\(index)", threadID: "t\(index)",
                            from: MailAddress(email: "a@x.com"), subject: "s",
                            date: Date(), labelIDs: [], snippet: "")
            ])
        }

        let results = try await provider.searchThreads(query: "anything", limit: 3)

        #expect(results.count == 3)
        #expect(provider.searchThreadsCallCount == 1)
    }

    @Test("searchThreads can simulate a rate-limit distinct from an empty result")
    func searchThreadsSimulatesRateLimit() async throws {
        let provider = FakeMailProvider()
        provider.failures["searchThreads"] = [MailError.rateLimited(retryAfter: 5)]

        await #expect(throws: MailError.self) { try await provider.searchThreads(query: "q", limit: 10) }

        // The scripted failure is consumed; the next call succeeds and can
        // genuinely return nothing, which is a different outcome.
        provider.searchResults = []
        let results = try await provider.searchThreads(query: "q", limit: 10)
        #expect(results.isEmpty)
    }
}
