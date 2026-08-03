import Testing
import Foundation
@testable import RavenFeature

@Suite("Outbox")
@MainActor struct OutboxTests {
    private func makeOutbox(_ provider: FakeMailProvider, maxAttempts: Int = 3,
                            accountID: String? = nil)
        -> (Outbox, InMemoryDocumentStore) {
        let documents = InMemoryDocumentStore()
        return (Outbox(documents: documents, provider: provider, maxAttempts: maxAttempts,
                       accountID: accountID), documents)
    }

    private func aMessage() -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "b@x.com")], subject: "Hi", bodyText: "There")
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

    @Test("a persistence failure after a successful send does not resend the entry")
    func persistenceFailureAfterSendDoesNotResend() async throws {
        let provider = FakeMailProvider()
        let (outbox, documents) = makeOutbox(provider)
        try outbox.enqueue(.send(OutgoingMessage(
            to: [MailAddress(email: "b@x.com")], subject: "Hi", bodyText: "There")))

        // Allow the enqueue write and the in-flight-marking write to land, but
        // drop the write that would record the post-send removal — simulating
        // a crash (or a silent disk failure) between the send succeeding and
        // that success being persisted.
        documents.dropWritesAfter = documents.writeLog.count + 1

        await outbox.drain()
        #expect(provider.sentMessages.count == 1)

        let revived = Outbox(documents: documents, provider: provider, maxAttempts: 3)
        #expect(revived.pending().isEmpty)
        #expect(revived.needsReview().count == 1)
    }

    @Test("an entry left marked in-flight by a previous process is surfaced, not resent")
    func inFlightEntrySurfacedNotResent() async throws {
        let provider = FakeMailProvider()
        let (outbox, documents) = makeOutbox(provider)
        try outbox.enqueue(.send(OutgoingMessage(
            to: [MailAddress(email: "b@x.com")], subject: "Hi", bodyText: "There")))

        // Drop every write from here on, so drain()'s in-flight marker
        // persists but nothing past it does — as if the process died right
        // after handing the message to the provider.
        documents.dropWritesAfter = documents.writeLog.count + 1

        await outbox.drain()
        #expect(provider.sentMessages.count == 1)

        let revived = Outbox(documents: documents, provider: provider, maxAttempts: 3)
        #expect(revived.pending().isEmpty)
        #expect(revived.needsReview().count == 1)
        #expect(revived.needsReview().first?.lastError?.isEmpty == false)

        // Draining the revived outbox must not resend the in-flight entry.
        await revived.drain()
        #expect(provider.sentMessages.count == 1)
    }

    // MARK: Reentrancy

    @Test("two overlapping drains transmit a queued send exactly once")
    func overlappingDrainsSendOnce() async throws {
        let provider = FakeMailProvider()
        provider.holdsSend = true
        let (outbox, _) = makeOutbox(provider)
        try outbox.enqueue(.send(aMessage()))

        // Drain A starts and parks inside `provider.send`, having freed the
        // main actor exactly as a real network call does.
        let drainA = Task { await outbox.drain() }
        await provider.waitUntilSendEntered()

        // Open the gate for any FURTHER send, so drain B cannot park and this
        // test can never deadlock: B either declines to send (correct) or
        // sends immediately (the defect). A stays parked.
        provider.allowFutureSends()

        // Drain B — this is the sync timer's tick, a `send_draft` call, or the
        // Settings retry button arriving while A is still on the wire. Before
        // the fix it saw the same entry as pending, re-marked it in-flight and
        // sent the email a second time.
        await outbox.drain()
        #expect(provider.sentMessages.isEmpty,
                "the overlapping drain must not transmit the entry A already has in flight")

        provider.releaseSend()
        await drainA.value

        #expect(provider.sentMessages.count == 1, "the recipient must not get the email twice")
        #expect(outbox.pending().isEmpty)
        #expect(outbox.inFlight().isEmpty)
        #expect(outbox.deadLettered().isEmpty)
    }

    @Test("an entry a drain has in flight is not pending, and reads as queued rather than sent")
    func inFlightEntryIsNotPendingAndNotSent() async throws {
        let provider = FakeMailProvider()
        provider.holdsSend = true
        let (outbox, _) = makeOutbox(provider)
        let entryID = try outbox.enqueue(.send(aMessage()))

        let drainA = Task { await outbox.drain() }
        await provider.waitUntilSendEntered()

        #expect(outbox.pending().isEmpty, "an in-flight entry must never be re-eligible")
        #expect(outbox.inFlight().map(\.id) == [entryID])
        // The load-bearing part: while the send is unconfirmed, nothing may
        // read it as a success — that is what would destroy a user's draft.
        #expect(outbox.outcome(for: entryID) == .queued(inFlight: true))

        provider.releaseSend()
        await drainA.value
        #expect(outbox.outcome(for: entryID) == .sent)
    }

    // MARK: Account scoping

    @Test("a send queued for one account is never transmitted from another")
    func queuedSendCannotCrossAccounts() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider, accountID: "a1")
        try outbox.enqueue(.send(aMessage()))

        // A different account connects (sign out of a1, sign in to a2).
        outbox.accountID = "a2"
        await outbox.drain()

        #expect(provider.sentMessages.isEmpty,
                "a1's queued mail must not go out from a2's mailbox")
        #expect(outbox.pending().isEmpty)
    }

    @Test("purging an account drops only that account's entries")
    func purgeDropsOnlyThatAccount() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider, accountID: "a1")
        try outbox.enqueue(.send(aMessage()))
        outbox.accountID = "a2"
        let keep = try outbox.enqueue(.send(aMessage()))

        outbox.purge(accountID: "a1")

        #expect(outbox.pending().map(\.id) == [keep])
    }
}
