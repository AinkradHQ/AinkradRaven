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

    // MARK: Legacy entries with no accountID

    @Test("a legacy entry with no accountID is surfaced for review, not stranded, once it has no default account to fall back to")
    func legacyEntryWithNoAccountIDNeedsReview() async throws {
        let documents = InMemoryDocumentStore()
        // Simulate a pre-M1 queue: encoded directly, with no `accountID`
        // (`Outbox.enqueue` today would always stamp one).
        let legacy = OutboxEntry(operation: .send(aMessage()))
        #expect(legacy.accountID == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        documents.setData(try encoder.encode([legacy]), forKey: DocumentKeys.outbox)

        // Two real accounts routed, neither claimed as the outbox's default —
        // exactly the case where the nil stamp's usual fallback (claimed
        // account, else the sole provider) cannot resolve anything.
        let router = MailProviderRouter()
        let p1 = FakeMailProvider(accountID: "a1")
        let p2 = FakeMailProvider(accountID: "a2")
        router.attach(p1, accountID: "a1")
        router.attach(p2, accountID: "a2")
        let outbox = Outbox(documents: documents, router: router)

        // Held for review rather than silently stranded in `pending()`
        // forever, and rather than being guessed onto either mailbox.
        #expect(outbox.pending().isEmpty)
        #expect(outbox.needsReview().map(\.id) == [legacy.id])
        #expect(outbox.needsReview().first?.lastError?.isEmpty == false)

        await outbox.drain()
        #expect(p1.sentMessages.isEmpty, "a legacy unattributed entry must never be guessed onto a1")
        #expect(p2.sentMessages.isEmpty, "a legacy unattributed entry must never be guessed onto a2")
    }

    @Test("a legacy entry with no accountID drains normally while it still resolves to a sole account")
    func legacyEntryWithNoAccountIDResolvesToSoleAccount() async throws {
        let documents = InMemoryDocumentStore()
        let legacy = OutboxEntry(operation: .send(aMessage()))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        documents.setData(try encoder.encode([legacy]), forKey: DocumentKeys.outbox)

        let provider = FakeMailProvider()
        let outbox = Outbox(documents: documents, provider: provider)

        // Exactly one account is connected, so the existing nil-stamp
        // fallback (the sole attached provider) is unambiguous — this must
        // NOT be redirected into needsReview.
        #expect(outbox.needsReview().isEmpty)
        await outbox.drain()
        #expect(provider.sentMessages.count == 1)
        #expect(outbox.pending().isEmpty)
    }

    // MARK: Undo-send hold window (M3)

    @Test("a held entry is not transmitted before its window elapses, and transmits after")
    func heldEntryWaitsForItsWindow() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        let entryID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                         holdUntil: Date().addingTimeInterval(60),
                                         sendAt: nil, draftID: nil)

        await outbox.drain()
        #expect(provider.sentMessages.isEmpty, "a held entry must not transmit before its window elapses")
        #expect(outbox.pending().isEmpty, "a held entry is not eligible, so it must not appear as pending either")
        #expect(outbox.outcome(for: entryID) == .queued(inFlight: false))

        // Once the hold has elapsed (simulated here by re-enqueuing the same
        // message with an already-past `holdUntil` — the exact state
        // `pending()` sees once real wall-clock time passes the deadline —
        // draining transmits it via the normal path, no special-casing.
        let laterID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                         holdUntil: Date().addingTimeInterval(-1),
                                         sendAt: nil, draftID: nil)
        await outbox.drain()
        #expect(provider.sentMessages.count == 1)
        #expect(outbox.outcome(for: laterID) == .sent)
    }

    @Test("cancelling a held entry within its window returns the message and transmits nothing")
    func cancelHeldReturnsMessageAndTransmitsNothing() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        let message = aMessage()
        let entryID = try outbox.enqueue(.send(message), accountID: nil,
                                         holdUntil: Date().addingTimeInterval(60),
                                         sendAt: nil, draftID: "draft-1")

        let cancelled = outbox.cancelHeld(entryID)
        #expect(cancelled == message)

        await outbox.drain()
        #expect(provider.sentMessages.isEmpty, "a cancelled send must never transmit")
        #expect(outbox.pending().isEmpty)
        #expect(outbox.outcome(for: entryID) == .removedWithoutSending)
    }

    @Test("cancelHeld refuses an entry whose hold has already elapsed")
    func cancelHeldRefusesElapsedHold() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        let entryID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                         holdUntil: Date().addingTimeInterval(-1),
                                         sendAt: nil, draftID: nil)

        #expect(outbox.cancelHeld(entryID) == nil,
                "an elapsed hold is about to become eligible; cancelling it must be refused")
    }

    @Test("cancelHeld refuses an entry already in flight")
    func cancelHeldRefusesInFlight() async throws {
        let provider = FakeMailProvider()
        provider.holdsSend = true
        let (outbox, _) = makeOutbox(provider)
        let entryID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                         holdUntil: Date().addingTimeInterval(-1),
                                         sendAt: nil, draftID: nil)

        let drainTask = Task { await outbox.drain() }
        await provider.waitUntilSendEntered()
        provider.allowFutureSends()

        #expect(outbox.cancelHeld(entryID) == nil, "an in-flight send must never be cancelable")

        provider.releaseSend()
        await drainTask.value
    }

    // MARK: Scheduled send (M3)

    @Test("a scheduled entry waits for its time, then transmits via the normal drain path")
    func scheduledEntryWaitsThenTransmits() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        let futureID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                          holdUntil: nil,
                                          sendAt: Date().addingTimeInterval(3600),
                                          draftID: nil)

        await outbox.drain()
        #expect(provider.sentMessages.isEmpty, "a message scheduled for the future must not transmit yet")
        #expect(outbox.outcome(for: futureID) == .queued(inFlight: false))

        let dueID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                       holdUntil: nil,
                                       sendAt: Date().addingTimeInterval(-1),
                                       draftID: nil)
        await outbox.drain()
        #expect(provider.sentMessages.count == 1)
        #expect(outbox.outcome(for: dueID) == .sent)
        #expect(outbox.outcome(for: futureID) == .queued(inFlight: false),
                "the still-future entry must remain untouched by a drain that only frees the due one")
    }

    // MARK: Crash-and-restart preserves hold/schedule timing (M3)

    @Test("a crash-and-restart preserves a held entry's remaining hold and a scheduled entry's future time")
    func restartPreservesHoldAndScheduleTiming() async throws {
        let provider = FakeMailProvider()
        let (outbox, documents) = makeOutbox(provider)
        let heldID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                        holdUntil: Date().addingTimeInterval(3600),
                                        sendAt: nil, draftID: nil)
        let scheduledID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                             holdUntil: nil,
                                             sendAt: Date().addingTimeInterval(7200),
                                             draftID: nil)

        // Simulate the crash: a brand new `Outbox` loading the SAME
        // persisted documents, rather than a `Task.sleep` that would not
        // survive a real process death.
        let revived = Outbox(documents: documents, provider: provider, maxAttempts: 3)

        await revived.drain()
        #expect(provider.sentMessages.isEmpty,
                "both the held and scheduled entries must still be in the future after reload")
        #expect(revived.outcome(for: heldID) == .queued(inFlight: false))
        #expect(revived.outcome(for: scheduledID) == .queued(inFlight: false))
        #expect(revived.pending().isEmpty)
    }

    // MARK: One-shot wake (undo-send/scheduled-send skew fix)

    /// Requirement 1: a held entry drains promptly once its window elapses —
    /// via the one-shot wake `Outbox.enqueue` schedules — WITHOUT anyone
    /// calling `drain()` again after the initial (unsuccessful, because
    /// still held) one. A real 120s backstop tick is never simulated here;
    /// the hold below is a fraction of a second.
    @Test("a held entry drains on its own once its hold elapses, without the 120s tick")
    func wakeDrainsWhenHoldElapses() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        try outbox.enqueue(.send(aMessage()), accountID: nil,
                           holdUntil: Date().addingTimeInterval(0.15),
                           sendAt: nil, draftID: nil)

        // Nothing has transmitted yet — the hold has not elapsed.
        #expect(provider.sentMessages.isEmpty)

        // Wait past the hold WITHOUT calling drain() ourselves — only the
        // scheduled wake may cause this to transmit.
        try await Task.sleep(for: .seconds(1))
        #expect(provider.sentMessages.count == 1,
                "the one-shot wake must have drained this on its own")
        #expect(outbox.pending().isEmpty)
    }

    /// Requirement 2: with several pending entries, the wake targets the
    /// SOONEST one, and cancelling it moves the target to the next-soonest
    /// — not just "some" entry, and not stuck on the one just removed.
    @Test("the wake targets the soonest pending entry, and retargets when it is cancelled")
    func wakeRetargetsToNextSoonestOnCancel() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        // B is soonest, A is second-soonest.
        let laterID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                         holdUntil: Date().addingTimeInterval(0.5),
                                         sendAt: nil, draftID: nil)
        let soonerID = try outbox.enqueue(.send(aMessage()), accountID: nil,
                                          holdUntil: Date().addingTimeInterval(0.15),
                                          sendAt: nil, draftID: nil)

        // Cancel the soonest one before it fires — the wake must now be
        // retargeted at the later entry instead of firing (for nothing) at
        // the cancelled one's original due time.
        #expect(outbox.cancelHeld(soonerID) != nil)

        // Wait past what WAS the soonest entry's due time. If the wake had
        // not been retargeted, nothing would be left to observe either way
        // (the cancelled entry is gone) — the real assertion is below, once
        // we also pass the later entry's due time.
        try await Task.sleep(for: .seconds(0.3))
        #expect(provider.sentMessages.isEmpty,
                "the cancelled entry must not have transmitted, and the later one is not due yet")

        // Now pass the later (originally second-soonest, now the ONLY, and
        // therefore the retargeted wake's) entry's due time.
        try await Task.sleep(for: .seconds(0.5))
        #expect(provider.sentMessages.count == 1,
                "the retargeted wake must still fire for the remaining entry")
        #expect(outbox.outcome(for: laterID) == .sent)
    }

    /// Requirement 3: an entry that came due while the app was "closed" —
    /// simulated by constructing a fresh `Outbox` from persisted documents
    /// whose entry's `holdUntil` is already in the past — drains on launch,
    /// via the wake `init` re-derives from what it just loaded, not by
    /// waiting for the first 120s tick.
    @Test("an entry that came due while the app was closed drains on launch")
    func wakeDrainsPastDueEntryOnLaunch() async throws {
        let provider = FakeMailProvider()
        let documents = InMemoryDocumentStore()
        let pastDue = OutboxEntry(operation: .send(aMessage()),
                                  holdUntil: Date().addingTimeInterval(-30))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        documents.setData(try encoder.encode([pastDue]), forKey: DocumentKeys.outbox)

        // Constructing this is "launch" — nothing here calls drain()
        // explicitly.
        let revived = Outbox(documents: documents, provider: provider, maxAttempts: 3)
        #expect(provider.sentMessages.isEmpty, "not yet — only the wake, not the constructor itself, may drain")

        try await Task.sleep(for: .seconds(0.3))
        #expect(provider.sentMessages.count == 1,
                "the wake re-derived on launch must have drained the already-past-due entry")
        #expect(revived.pending().isEmpty)
    }

    /// Requirement 4: tearing down must cancel the pending wake — a torn-
    /// down instance must never fire. `teardownWake()` is what
    /// `RavenRuntime.teardown()` calls; exercised directly here since a full
    /// `RavenRuntime` is unnecessary to prove the `Outbox`-level guarantee.
    @Test("teardownWake cancels the pending wake — no drain fires after teardown")
    func teardownCancelsPendingWake() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        try outbox.enqueue(.send(aMessage()), accountID: nil,
                           holdUntil: Date().addingTimeInterval(0.15),
                           sendAt: nil, draftID: nil)

        outbox.teardownWake()

        // Fast-forward well past the due time. With the wake cancelled,
        // nothing may transmit — only the (absent, in this test) 120s tick
        // or an explicit drain() could, and neither happens here.
        try await Task.sleep(for: .seconds(1))
        #expect(provider.sentMessages.isEmpty,
                "a torn-down instance's cancelled wake must never fire")
        #expect(outbox.pending().count == 1, "the entry is eligible now, but nothing drained it")
    }

    /// Requirement 5: the 120s tick is a backstop that must still work even
    /// if the wake never fires (e.g. was never scheduled, or was cancelled
    /// by a `teardownWake()` that a caller then continues to use the
    /// instance past). Simulated here exactly as in the previous test —
    /// wake cancelled — but this time by explicitly calling `drain()`
    /// ourselves, standing in for the next scheduled tick.
    @Test("drain() still catches a due entry even if the wake never fires")
    func drainBackstopsAMissedWake() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        try outbox.enqueue(.send(aMessage()), accountID: nil,
                           holdUntil: Date().addingTimeInterval(0.05),
                           sendAt: nil, draftID: nil)
        outbox.teardownWake()   // the wake will never fire

        try await Task.sleep(for: .seconds(0.2))
        #expect(provider.sentMessages.isEmpty, "confirms the wake really did not fire")

        // Stand-in for the sync timer's next tick.
        await outbox.drain()
        #expect(provider.sentMessages.count == 1,
                "the backstop drain must still transmit the now-due entry")
    }
}
