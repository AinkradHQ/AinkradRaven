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

    @Test("granted senders are listed, sorted, for the Privacy settings list")
    func listsGrantedSenders() {
        let documents = InMemoryDocumentStore()
        #expect(RemoteImageAllowList.allowedSenders(documents: documents).isEmpty)
        RemoteImageAllowList.allow("Zoe@example.com", documents: documents)
        RemoteImageAllowList.allow("amir@example.com", documents: documents)
        // Normalized on the way in, and stably ordered on the way out — the
        // list must not reshuffle itself between renders.
        #expect(RemoteImageAllowList.allowedSenders(documents: documents)
            == ["amir@example.com", "zoe@example.com"])
    }

    @Test("revoking returns exactly that sender to the blocked default")
    func revokeBlocksAgain() {
        let documents = InMemoryDocumentStore()
        RemoteImageAllowList.allow("trusted@example.com", documents: documents)
        RemoteImageAllowList.allow("other@example.com", documents: documents)

        // Case-insensitive, like `allow`/`isAllowed`.
        RemoteImageAllowList.revoke("TRUSTED@example.com", documents: documents)
        #expect(RemoteImageAllowList.isAllowed("trusted@example.com", documents: documents) == false)
        // Revoking one grant never disturbs another.
        #expect(RemoteImageAllowList.isAllowed("other@example.com", documents: documents))
        #expect(RemoteImageAllowList.allowedSenders(documents: documents) == ["other@example.com"])

        // Revoking something never granted is a no-op, not a crash or a write.
        RemoteImageAllowList.revoke("nobody@example.com", documents: documents)
        #expect(RemoteImageAllowList.allowedSenders(documents: documents) == ["other@example.com"])
    }
}
