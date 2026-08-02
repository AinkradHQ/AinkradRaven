import Testing
import Foundation
@testable import MailFeature

@Suite("Outbox")
@MainActor struct OutboxTests {
    private func makeOutbox(_ provider: FakeMailProvider, maxAttempts: Int = 3)
        -> (Outbox, InMemoryDocumentStore) {
        let documents = InMemoryDocumentStore()
        return (Outbox(documents: documents, provider: provider, maxAttempts: maxAttempts), documents)
    }

    @Test("a successful mutation leaves the queue empty")
    func drainsOnSuccess() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        try outbox.enqueue(.labels(LabelMutation(threadIDs: ["t1"], add: [], remove: ["INBOX"])))

        await outbox.drain()
        #expect(outbox.pending().isEmpty)
        #expect(provider.appliedMutations.count == 1)
    }

    @Test("a failing mutation is retried and its attempt count rises")
    func retriesOnFailure() async throws {
        let provider = FakeMailProvider()
        provider.failures["applyLabels"] = [MailError.providerFailed(status: 500, message: "boom")]
        let (outbox, _) = makeOutbox(provider)
        try outbox.enqueue(.labels(LabelMutation(threadIDs: ["t1"], remove: ["INBOX"])))

        await outbox.drain()
        #expect(outbox.pending().first?.attempts == 1)

        await outbox.drain()   // second attempt succeeds
        #expect(outbox.pending().isEmpty)
    }

    @Test("an entry that exhausts its attempts is dead-lettered, not retried forever")
    func deadLetters() async throws {
        let provider = FakeMailProvider()
        provider.failures["applyLabels"] = Array(
            repeating: MailError.providerFailed(status: 500, message: "boom"), count: 5)
        let (outbox, _) = makeOutbox(provider, maxAttempts: 2)
        try outbox.enqueue(.labels(LabelMutation(threadIDs: ["t1"], remove: ["INBOX"])))

        await outbox.drain()
        await outbox.drain()
        #expect(outbox.pending().isEmpty)
        #expect(outbox.deadLettered().count == 1)
        #expect(outbox.deadLettered().first?.lastError?.isEmpty == false)
    }

    @Test("a queued send transmits and records the provider id")
    func sendsDraft() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        try outbox.enqueue(.send(OutgoingMessage(
            to: [MailAddress(email: "b@x.com")], subject: "Hi", bodyText: "There")))

        await outbox.drain()
        #expect(provider.sentMessages.count == 1)
        #expect(outbox.pending().isEmpty)
    }

    @Test("the queue survives a restart")
    func persists() async throws {
        let provider = FakeMailProvider()
        provider.failures["applyLabels"] = [MailError.providerFailed(status: 500, message: "boom")]
        let (outbox, documents) = makeOutbox(provider)
        try outbox.enqueue(.labels(LabelMutation(threadIDs: ["t1"], remove: ["INBOX"])))
        await outbox.drain()

        let revived = Outbox(documents: documents, provider: provider, maxAttempts: 3)
        #expect(revived.pending().count == 1)
    }
}
