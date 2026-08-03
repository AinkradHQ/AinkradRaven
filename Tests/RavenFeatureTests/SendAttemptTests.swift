import Testing
import Foundation
@testable import RavenFeature

/// `SendAttempt` is the single decision point both the human Send button
/// (`ComposeSurface`) and the agent tool (`send_draft`) go through. These
/// tests pin its one invariant — the draft is destroyed if and only if the
/// send genuinely went out — which is what the UI path was violating.
@Suite("SendAttempt")
@MainActor struct SendAttemptTests {
    private func message() -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "b@x.com")], subject: "s", bodyText: "b")
    }

    @Test("a genuine send reports sent and removes the draft")
    func successRemovesDraft() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, drain: outbox.drain)

        #expect(result.isSent)
        #expect(provider.sentMessages.count == 1)
        #expect(DraftBox.shared.draft(draftID) == nil)
    }

    @Test("a dead-lettered send keeps the draft and explains what happened")
    func deadLetteredKeepsDraft() async throws {
        let provider = FakeMailProvider()
        provider.failures["send"] = [MailError.notAuthenticated(accountID: "a1")]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider, maxAttempts: 1)
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, drain: outbox.drain)

        #expect(result.isSent == false)
        #expect(provider.sentMessages.isEmpty)
        #expect(DraftBox.shared.draft(draftID) != nil, "a failed send must not destroy the draft")
        #expect(result.message.isEmpty == false)
        DraftBox.shared.remove(draftID)
    }

    @Test("a still-queued send keeps the draft and does not claim success")
    func queuedKeepsDraft() async throws {
        let provider = FakeMailProvider()
        provider.failures["send"] = [MailError.providerFailed(status: 500, message: "boom")]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, drain: outbox.drain)

        #expect(result.outcome == .queued(inFlight: false))
        #expect(result.isSent == false)
        #expect(DraftBox.shared.draft(draftID) != nil)
        DraftBox.shared.remove(draftID)
    }

    /// The UI defect in miniature: a send that is still on the wire because a
    /// concurrent drain owns it must NOT read as success. Before the fix the
    /// composer cleared itself and deleted the draft on exactly this path.
    @Test("a send still in flight under a concurrent drain keeps the draft")
    func inFlightKeepsDraft() async throws {
        let provider = FakeMailProvider()
        provider.holdsSend = true
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)

        // A first send is already parked on the network, so the drain this
        // attempt asks for is a no-op and its own entry stays queued.
        try outbox.enqueue(.send(message()))
        let blocking = Task { await outbox.drain() }
        await provider.waitUntilSendEntered()
        // Never park a second send, so this test asserts rather than hangs.
        provider.allowFutureSends()

        let draftID = try DraftBox.shared.save(message())
        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, drain: outbox.drain)

        #expect(result.isSent == false)
        #expect(DraftBox.shared.draft(draftID) != nil)

        provider.releaseSend()
        await blocking.value
        DraftBox.shared.remove(draftID)
    }

    @Test("send_draft and the compose Send button share one outcome decision")
    func bothPathsShareTheSameLogic() async throws {
        // Same provider behaviour, same expectation, two entry points. The
        // agent path routes through RavenMCPOperations; the UI path calls
        // SendAttempt directly, exactly as ComposeSurface.send() does.
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let agentProvider = FakeMailProvider()
        agentProvider.failures["send"] = [MailError.notAuthenticated(accountID: "a1")]
        let agentOutbox = Outbox(documents: InMemoryDocumentStore(),
                                 provider: agentProvider, maxAttempts: 1)
        let agentDraft = try DraftBox.shared.save(message())
        let agentResult = await RavenMCPOperations.run(
            "send_draft", arguments: #"{"draft_id":"\#(agentDraft)"}"#,
            store: store, outbox: agentOutbox)

        let uiProvider = FakeMailProvider()
        uiProvider.failures["send"] = [MailError.notAuthenticated(accountID: "a1")]
        let uiOutbox = Outbox(documents: InMemoryDocumentStore(),
                              provider: uiProvider, maxAttempts: 1)
        let uiDraft = try DraftBox.shared.save(message())
        let uiResult = try await SendAttempt.send(message(), draftID: uiDraft,
                                                  outbox: uiOutbox, drain: uiOutbox.drain)

        // Both must refuse to claim success and both must keep the draft.
        #expect(agentResult.isError)
        #expect(uiResult.isSent == false)
        #expect(DraftBox.shared.draft(agentDraft) != nil)
        #expect(DraftBox.shared.draft(uiDraft) != nil)
        DraftBox.shared.remove(agentDraft)
        DraftBox.shared.remove(uiDraft)
    }
}
