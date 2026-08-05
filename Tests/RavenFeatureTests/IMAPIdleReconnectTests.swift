import Testing
import Foundation
@testable import RavenFeature

/// What a dropped IDLE connection does: reconnect on a doubling backoff, keep the
/// arrival that was already seen, and never invent a delta pass the cursor did not
/// ask for.
///
/// Split from `IMAPIdleTests` for the repo's line limit. **No test here waits out a
/// backoff:** the schedule is a pure function, asserted directly, and every delay
/// the watcher actually waits on is parked on `IMAPIdleHarness.FakeClock` and
/// released by the test.
@Suite struct IMAPIdleReconnectTests {

    // MARK: - The schedule, as a pure function

    /// `1s, 2s, 4s, 8s…` capped at two minutes, asserted for the whole schedule in
    /// one expression rather than by running eight reconnects.
    @Test func backoffDoublesFromOneSecondAndCapsAtTwoMinutes() {
        let backoff = IMAPIdleBackoff()
        let schedule = (1...10).map { backoff.delay(attempt: $0) }
        #expect(schedule == [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                             .seconds(16), .seconds(32), .seconds(64),
                             .seconds(120), .seconds(120), .seconds(120)])
    }

    /// Attempt 0 and negative attempts are the first delay, not a zero-length wait:
    /// a caller that got its counter wrong must still back off.
    @Test func backoffFloorsAtTheFirstDelay() {
        let backoff = IMAPIdleBackoff(first: .seconds(3), ceiling: .seconds(10))
        #expect(backoff.delay(attempt: 0) == .seconds(3))
        #expect(backoff.delay(attempt: 1) == .seconds(3))
        #expect(backoff.delay(attempt: 2) == .seconds(6))
        #expect(backoff.delay(attempt: 3) == .seconds(10))
    }

    /// A `first` larger than `ceiling` still saturates rather than exceeding it.
    @Test func backoffNeverExceedsItsCeiling() {
        let backoff = IMAPIdleBackoff(first: .seconds(300), ceiling: .seconds(120))
        #expect(backoff.delay(attempt: 1) == .seconds(120))
        #expect(backoff.delay(attempt: 5) == .seconds(120))
    }

    /// A watcher against a permanently dead server must saturate, not overflow the
    /// doubling. 2^63 seconds is not a delay; it is a crash or a negative wait.
    @Test func backoffSaturatesForAVeryLargeAttemptCount() {
        let backoff = IMAPIdleBackoff()
        #expect(backoff.delay(attempt: 1_000) == .seconds(120))
        #expect(backoff.delay(attempt: Int.max / 2) == .seconds(120))
    }

    // MARK: - A real drop

    /// A drop mid-IDLE reconnects, and the delays it waits are the schedule above.
    ///
    /// Two drops with no completed cycle in between, so the doubling is what is
    /// asserted — `[1s]` alone would also hold for a watcher with a fixed delay.
    @Test func aDroppedConnectionReconnectsWithADoublingBackoff() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let recorder = IMAPIdleHarness.SyncRecorder()
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(), IMAPIdleHarness.Script(), IMAPIdleHarness.Script(),
        ])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: recorder.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }

        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 0) else { return }
        guard let first = await server.connection(0) else { return }
        await first.transport.close()

        guard await IMAPIdleHarness.waitForSleep(clock, .seconds(1)) else { return }
        #expect(await watcher.backoffDelays == [.seconds(1)])
        #expect(await watcher.connectionCount == 1)
        #expect(await watcher.cycleCount == 0)

        #expect(await clock.release(.seconds(1)))
        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 1) else { return }
        #expect(await watcher.connectionCount == 2)
        guard let second = await server.connection(1) else { return }
        await second.transport.close()

        guard await IMAPIdleHarness.waitForSleep(clock, .seconds(2)) else { return }
        #expect(await watcher.backoffDelays == [.seconds(1), .seconds(2)])
        // Nothing invented a delta pass out of a reconnect.
        #expect(await recorder.syncCount == 0)
        // Both dead leases were handed back — the reconnect loop cannot leak one.
        #expect(await server.released == 2)

        await watcher.stop()
        #expect(await clock.release(.seconds(2)))
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// A connection that completed at least one cycle proves the server is
    /// reachable, so a later drop restarts the schedule at `first` instead of
    /// continuing to double.
    ///
    /// The assertion is `[1s, 1s]` where the test above got `[1s, 2s]` from the same
    /// code path — the only difference is a completed cycle, which is exactly what
    /// `idledSinceReconnect` records.
    @Test func aCompletedCycleResetsTheBackoffSchedule() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(), IMAPIdleHarness.Script(), IMAPIdleHarness.Script(),
        ])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }

        // Connection 1: drop with no completed cycle → attempt 1.
        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 0) else { return }
        guard let first = await server.connection(0) else { return }
        await first.transport.close()
        guard await IMAPIdleHarness.waitForSleep(clock, .seconds(1)) else { return }
        #expect(await watcher.backoffDelays == [.seconds(1)])
        #expect(await clock.release(.seconds(1)))

        // Connection 2: complete a cycle (the 29-minute deadline expires and DONE
        // goes out), THEN drop.
        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 1) else { return }
        #expect(await clock.release(.seconds(29 * 60)))
        guard await IMAPIdleHarness.waitUntil("a completed cycle", {
            await watcher.cycleCount == 1
        }) else { return }
        guard let second = await server.connection(1) else { return }
        await second.transport.close()

        guard await IMAPIdleHarness.waitUntil("the reset backoff", {
            await watcher.backoffDelays.count == 2
        }) else { return }
        #expect(await watcher.backoffDelays == [.seconds(1), .seconds(1)])

        await watcher.stop()
        #expect(await clock.release(.seconds(1)))
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    // MARK: - The cursor

    /// An arrival seen just before the drop is still synced after the reconnect.
    ///
    /// This is the half of "never loses the cursor" the watcher can actually break:
    /// its only output is "run a delta pass", so losing the arrival means the pass
    /// never runs and the message waits out the 120-second poll. What the pass then
    /// does to the stored cursor is Task 12's hold-don't-advance discipline, asserted
    /// in `IMAPDeltaStrategyTests` — the watcher is given no way to touch it, and the
    /// recorder's cursor being untouched here says exactly that and no more.
    ///
    /// The backoff is set to 50 ms so it cannot be confused with the one-second
    /// coalesce window on the shared clock: releasing by duration has to name one or
    /// the other, and two waits of the same length would make the release ambiguous.
    @Test func anArrivalSeenBeforeADropIsStillSyncedAfterReconnecting() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let recorder = IMAPIdleHarness.SyncRecorder()
        let before = await recorder.cursor
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(), IMAPIdleHarness.Script(),
        ])
        let watcher = IMAPIdleWatcher(
            provider: IMAPIdleHarness.provider(server), clock: clock,
            backoff: IMAPIdleBackoff(first: .milliseconds(50), ceiling: .seconds(120)),
            onNotification: recorder.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }

        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 0) else { return }
        guard let first = await server.connection(0) else { return }
        await first.transport.enqueue(
            try IMAPDeltaHarness.fixtureText("imap-idle-one-arrival"))
        guard await IMAPIdleHarness.waitUntil("the arrival", {
            await watcher.notificationCount == 1
        }) else { return }
        #expect(await recorder.syncCount == 0)

        // Drop BEFORE the window closes: the pending arrival is in the debounce, not
        // yet in a pass.
        await first.transport.close()
        guard await IMAPIdleHarness.waitForSleep(clock, .milliseconds(50)) else { return }
        #expect(await clock.release(.milliseconds(50)))
        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 1) else { return }

        // Now let the window close. The arrival seen on the dead connection is
        // still owed a pass.
        #expect(await clock.release(.seconds(1)))
        guard await IMAPIdleHarness.waitUntil("the surviving pass", {
            await recorder.syncCount == 1
        }) else { return }
        #expect(await recorder.syncCount == 1)
        #expect(await recorder.cursor == before)

        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// A reconnect on its own triggers NO delta pass.
    ///
    /// The counterweight to the test above: a watcher that flushed unconditionally
    /// on every reconnect would pass that one and fail this one, and it would turn a
    /// flapping connection into a delta pass per reconnect — a self-inflicted rate
    /// limit against the account.
    @Test func aBareReconnectTriggersNoDeltaPass() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let recorder = IMAPIdleHarness.SyncRecorder()
        let before = await recorder.cursor
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(), IMAPIdleHarness.Script(),
        ])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: recorder.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }

        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 0) else { return }
        guard let first = await server.connection(0) else { return }
        await first.transport.close()
        guard await IMAPIdleHarness.waitForSleep(clock, .seconds(1)) else { return }
        #expect(await clock.release(.seconds(1)))
        guard await IMAPIdleHarness.waitUntilIdling(server, clock, connection: 1) else { return }

        #expect(await recorder.syncCount == 0)
        #expect(await recorder.cursor == before)
        // No coalesce window was ever opened, so there is nothing pending either.
        #expect(await clock.requestCount(of: .seconds(1)) == 1) // the backoff only
        #expect(await watcher.notificationCount == 0)

        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// Cancelling the task that runs `run()` stops the watcher rather than leaving
    /// the connection and its lease behind.
    @Test func cancellingTheRunTaskStopsAndReleases() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }

        task.cancel()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
        #expect(await server.isBalanced)
        guard let connection = await server.connection(0) else { return }
        #expect(await connection.session.inFlightCount == 0)
        #expect(await connection.session.abandonedTagCount == 0)
    }
}
