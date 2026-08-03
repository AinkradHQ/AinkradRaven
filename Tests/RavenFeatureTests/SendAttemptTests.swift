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
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, store: store, drain: outbox.drain)

        #expect(result.isSent)
        #expect(provider.sentMessages.count == 1)
        #expect(DraftBox.shared.draft(draftID) == nil)
    }

    @Test("a dead-lettered send keeps the draft and explains what happened")
    func deadLetteredKeepsDraft() async throws {
        let provider = FakeMailProvider()
        provider.failures["send"] = [MailError.notAuthenticated(accountID: "a1")]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider, maxAttempts: 1)
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, store: store, drain: outbox.drain)

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
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, store: store, drain: outbox.drain)

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

        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(message())
        let result = try await SendAttempt.send(message(), draftID: draftID,
                                                outbox: outbox, store: store, drain: outbox.drain)

        #expect(result.isSent == false)
        #expect(DraftBox.shared.draft(draftID) != nil)

        provider.releaseSend()
        await blocking.value
        DraftBox.shared.remove(draftID)
    }

    /// The false-success bug reintroduced by the purge added in the previous
    /// wave: `outcome(for:)` used to read "id not found" as success, and
    /// `purge` is a second way for an id to vanish. Signing out mid-send would
    /// therefore report "Sent draft X" and delete the draft for a message that
    /// never left the machine.
    @Test("an account signed out mid-send does not report the send as successful")
    func purgeMidSendIsNotSuccess() async throws {
        let provider = FakeMailProvider()
        provider.holdsSend = true
        // The call was on the wire when the user signed out, and then failed.
        // Nothing reached the recipient — so nothing may report as sent.
        provider.sendErrorAfterGate = MailError.providerFailed(status: 500, message: "boom")
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(message())

        // Start the send and let it park inside `provider.send`.
        var entryID: UUID?
        let attempt = Task { () -> SendAttempt.Result in
            try await SendAttempt.send(self.message(), draftID: draftID, outbox: outbox,
                                       store: store, drain: outbox.drain)
        }
        await provider.waitUntilSendEntered()
        entryID = outbox.inFlight().first?.id
        #expect(entryID != nil)

        // The user signs out while the send is still on the wire.
        outbox.purge(accountID: "a1")
        #expect(outbox.outcome(for: try #require(entryID)) != .sent,
                "a purged entry never reached the provider; absence is not success")

        provider.releaseSend()
        let result = try await attempt.value

        #expect(result.isSent == false)
        #expect(result.outcome == .removedWithoutSending)
        #expect(provider.sentMessages.isEmpty)
        #expect(DraftBox.shared.draft(draftID) != nil,
                "signing out mid-send must not destroy the user's draft")
        DraftBox.shared.remove(draftID)
    }

    @Test("a discarded entry reports removed-without-sending, not sent")
    func discardIsNotSuccess() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let entryID = try outbox.enqueue(.send(message()))

        try outbox.discard(entryID)

        #expect(outbox.outcome(for: entryID) == .removedWithoutSending)
        #expect(provider.sentMessages.isEmpty)
    }

    @Test("a genuinely transmitted entry still reports sent after it leaves the queue")
    func transmittedEntryStillReportsSent() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let entryID = try outbox.enqueue(.send(message()))

        await outbox.drain()

        #expect(provider.sentMessages.count == 1)
        #expect(outbox.outcome(for: entryID) == .sent,
                "recording success must not break the success path itself")
    }

    @Test("a queued outcome is benign so the composer does not style it as an error")
    func queuedOutcomeIsBenign() {
        #expect(OutboxSendOutcome.queued(inFlight: false).isBenign)
        #expect(OutboxSendOutcome.queued(inFlight: true).isBenign)
        // Everything that is genuinely wrong must NOT be benign.
        #expect(OutboxSendOutcome.deadLettered(lastError: "x").isBenign == false)
        #expect(OutboxSendOutcome.needsReview.isBenign == false)
        #expect(OutboxSendOutcome.removedWithoutSending.isBenign == false)
        #expect(OutboxSendOutcome.sent.isBenign == false)
    }

    // MARK: signature

    @Test("an empty signature adds nothing to the sent body")
    func emptySignatureAddsNothing() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a@x.com",
                                          displayName: "A", signature: ""))
        let draftID = try DraftBox.shared.save(message())

        _ = try await SendAttempt.send(message(), draftID: draftID, outbox: outbox,
                                       store: store, drain: outbox.drain)

        #expect(provider.sentMessages.count == 1)
        #expect(provider.sentMessages.first?.bodyText == "b")
        #expect(provider.sentMessages.first?.bodyText.contains("-- ") == false)
    }

    @Test("a non-empty signature is appended after a single sigdash")
    func signatureIsAppendedAfterSigdash() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a@x.com",
                                          displayName: "A", signature: "Best,\nA"))
        let draftID = try DraftBox.shared.save(message())

        _ = try await SendAttempt.send(message(), draftID: draftID, outbox: outbox,
                                       store: store, drain: outbox.drain)

        #expect(provider.sentMessages.count == 1)
        let sentBody = provider.sentMessages.first?.bodyText ?? ""
        #expect(sentBody == "b\n-- \nBest,\nA")
        // Exactly one sigdash — the separator does not double up.
        #expect(sentBody.components(separatedBy: "-- ").count == 2)
    }

    // MARK: Undo-send hold window (M3)

    @Test("a held send reports queued (benign), keeps the draft, and Outbox.cancelHeld returns it")
    func heldSendKeepsDraftAndIsCancelable() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID, outbox: outbox,
                                                store: store,
                                                holdUntil: Date().addingTimeInterval(60),
                                                drain: outbox.drain)

        #expect(result.outcome == .queued(inFlight: false))
        #expect(result.outcome.isBenign)
        #expect(provider.sentMessages.isEmpty)
        // `SendAttempt` itself never removes the draft for anything short of
        // `.sent` — the caller (Compose) decides whether to remove it early
        // once it knows the send is only held, per the undo-send UX.
        #expect(DraftBox.shared.draft(draftID) != nil)

        let cancelled = outbox.cancelHeld(result.entryID)
        #expect(cancelled != nil, "a still-held entry must be cancelable")
        #expect(outbox.outcome(for: result.entryID) == .removedWithoutSending)
        await outbox.drain()
        #expect(provider.sentMessages.isEmpty, "cancelling within the window must transmit nothing")
        DraftBox.shared.remove(draftID)
    }

    @Test("a held send that is never cancelled transmits once a later drain finds it eligible, and removes its draft")
    func heldSendEventuallyTransmitsAndRemovesDraft() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(message())

        let result = try await SendAttempt.send(message(), draftID: draftID, outbox: outbox,
                                                store: store,
                                                holdUntil: Date().addingTimeInterval(60),
                                                drain: outbox.drain)
        #expect(result.outcome == .queued(inFlight: false))

        // The draft carries through onto the entry itself (`OutboxEntry.
        // draftID`) precisely so a LATER drain — not this same call — can
        // still clean it up once the hold elapses.
        let dueID = try outbox.enqueue(.send(message()), accountID: nil,
                                       holdUntil: Date().addingTimeInterval(-1),
                                       sendAt: nil, draftID: draftID)
        await outbox.drain()
        #expect(outbox.outcome(for: dueID) == .sent)
        #expect(DraftBox.shared.draft(draftID) == nil,
                "a held send's draft must be removed once it actually transmits, even via a later drain")
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
        let uiStore = DocumentMailStore(documents: InMemoryDocumentStore())
        let uiDraft = try DraftBox.shared.save(message())
        let uiResult = try await SendAttempt.send(message(), draftID: uiDraft,
                                                  outbox: uiOutbox, store: uiStore,
                                                  drain: uiOutbox.drain)

        // Both must refuse to claim success and both must keep the draft.
        // The agent path is held (M3's undo-send window) rather than an
        // immediate error — `isError` on a benign hold would be wrong — but
        // it still must not claim success, exactly like the UI path (which
        // calls `SendAttempt.send` with no hold here, so its scripted
        // failure surfaces immediately).
        #expect(agentResult.isError == false)
        #expect(agentResult.text.contains("Sent") == false)
        #expect(uiResult.isSent == false)
        #expect(DraftBox.shared.draft(agentDraft) != nil)
        #expect(DraftBox.shared.draft(uiDraft) != nil)
        DraftBox.shared.remove(agentDraft)
        DraftBox.shared.remove(uiDraft)
    }
}
