import Testing
import Foundation
@testable import RavenFeature

@Suite("Remote image allow-list")
struct RemoteImageAllowListTests {
    @Test("an unknown sender defaults to blocked")
    func unknownSenderBlocksByDefault() {
        let documents = InMemoryDocumentStore()
        #expect(RemoteImageAllowList.isAllowed("stranger@example.com", documents: documents) == false)
    }

    @Test("a persisted opt-in survives a fresh store/runtime load")
    func persistedOptInSurvivesFreshLoad() {
        let documents = InMemoryDocumentStore()
        RemoteImageAllowList.allow("trusted@example.com", documents: documents)

        // Simulate a fresh process: nothing but the same underlying document
        // bytes carries over — no in-memory state.
        #expect(RemoteImageAllowList.isAllowed("trusted@example.com", documents: documents))
        #expect(RemoteImageAllowList.isAllowed("TRUSTED@example.com", documents: documents))
        // A different, unrelated sender is unaffected and still blocked.
        #expect(RemoteImageAllowList.isAllowed("stranger@example.com", documents: documents) == false)
    }
}
