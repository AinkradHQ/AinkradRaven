import Foundation
import Testing

@testable import RavenFeature

/// Undo-send holds, scheduled sends, their survival across a restart, and the
/// one-shot wake that drains them. Split out of `OutboxTests`.
@Suite("Outbox hold and wake")
@MainActor struct OutboxHoldAndWakeTests: OutboxTestSupport {
    // MARK: Undo-send hold window (M3)

    @Test("a held entry is not transmitted before its window elapses, and transmits after")
    func heldEntryWaitsForItsWindow() async throws {
        let provider = FakeMailProvider()
        let (outbox, _) = makeOutbox(provider)
        let entryID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
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
        let laterID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
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
        let entryID = try outbox.enqueue(
            .send(message), accountID: nil,
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
        let entryID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: Date().addingTimeInterval(-1),
            sendAt: nil, draftID: nil)

        #expect(
            outbox.cancelHeld(entryID) == nil,
            "an elapsed hold is about to become eligible; cancelling it must be refused")
    }

    @Test("cancelHeld refuses an entry already in flight")
    func cancelHeldRefusesInFlight() async throws {
        let provider = FakeMailProvider()
        provider.holdsSend = true
        let (outbox, _) = makeOutbox(provider)
        let entryID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
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
        let futureID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: nil,
            sendAt: Date().addingTimeInterval(3600),
            draftID: nil)

        await outbox.drain()
        #expect(provider.sentMessages.isEmpty, "a message scheduled for the future must not transmit yet")
        #expect(outbox.outcome(for: futureID) == .queued(inFlight: false))

        let dueID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: nil,
            sendAt: Date().addingTimeInterval(-1),
            draftID: nil)
        await outbox.drain()
        #expect(provider.sentMessages.count == 1)
        #expect(outbox.outcome(for: dueID) == .sent)
        #expect(
            outbox.outcome(for: futureID) == .queued(inFlight: false),
            "the still-future entry must remain untouched by a drain that only frees the due one")
    }

    // MARK: Crash-and-restart preserves hold/schedule timing (M3)

    @Test("a crash-and-restart preserves a held entry's remaining hold and a scheduled entry's future time")
    func restartPreservesHoldAndScheduleTiming() async throws {
        let provider = FakeMailProvider()
        let (outbox, documents) = makeOutbox(provider)
        let heldID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: Date().addingTimeInterval(3600),
            sendAt: nil, draftID: nil)
        let scheduledID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: nil,
            sendAt: Date().addingTimeInterval(7200),
            draftID: nil)

        // Simulate the crash: a brand new `Outbox` loading the SAME
        // persisted documents, rather than a `Task.sleep` that would not
        // survive a real process death.
        let revived = Outbox(documents: documents, provider: provider, maxAttempts: 3)

        await revived.drain()
        #expect(
            provider.sentMessages.isEmpty,
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
        try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: Date().addingTimeInterval(0.15),
            sendAt: nil, draftID: nil)

        // Nothing has transmitted yet — the hold has not elapsed.
        #expect(provider.sentMessages.isEmpty)

        // Wait past the hold WITHOUT calling drain() ourselves — only the
        // scheduled wake may cause this to transmit.
        try await Task.sleep(for: .seconds(1))
        #expect(
            provider.sentMessages.count == 1,
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
        let laterID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: Date().addingTimeInterval(0.5),
            sendAt: nil, draftID: nil)
        let soonerID = try outbox.enqueue(
            .send(aMessage()), accountID: nil,
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
        #expect(
            provider.sentMessages.isEmpty,
            "the cancelled entry must not have transmitted, and the later one is not due yet")

        // Now pass the later (originally second-soonest, now the ONLY, and
        // therefore the retargeted wake's) entry's due time.
        try await Task.sleep(for: .seconds(0.5))
        #expect(
            provider.sentMessages.count == 1,
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
        let pastDue = OutboxEntry(
            operation: .send(aMessage()),
            holdUntil: Date().addingTimeInterval(-30))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        documents.setData(try encoder.encode([pastDue]), forKey: DocumentKeys.outbox)

        // Constructing this is "launch" — nothing here calls drain()
        // explicitly.
        let revived = Outbox(documents: documents, provider: provider, maxAttempts: 3)
        #expect(provider.sentMessages.isEmpty, "not yet — only the wake, not the constructor itself, may drain")

        try await Task.sleep(for: .seconds(0.3))
        #expect(
            provider.sentMessages.count == 1,
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
        try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: Date().addingTimeInterval(0.15),
            sendAt: nil, draftID: nil)

        outbox.teardownWake()

        // Fast-forward well past the due time. With the wake cancelled,
        // nothing may transmit — only the (absent, in this test) 120s tick
        // or an explicit drain() could, and neither happens here.
        try await Task.sleep(for: .seconds(1))
        #expect(
            provider.sentMessages.isEmpty,
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
        try outbox.enqueue(
            .send(aMessage()), accountID: nil,
            holdUntil: Date().addingTimeInterval(0.05),
            sendAt: nil, draftID: nil)
        outbox.teardownWake()  // the wake will never fire

        try await Task.sleep(for: .seconds(0.2))
        #expect(provider.sentMessages.isEmpty, "confirms the wake really did not fire")

        // Stand-in for the sync timer's next tick.
        await outbox.drain()
        #expect(
            provider.sentMessages.count == 1,
            "the backstop drain must still transmit the now-due entry")
    }
}
