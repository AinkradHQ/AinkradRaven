import Testing
import Foundation
@testable import RavenFeature

/// Task 14's near-push path: `IDLE` only when advertised, re-idled on a 29-minute
/// deadline, `DONE` before anything else on the wire, and a burst of arrival
/// notifications collapsed onto ONE delta pass.
///
/// Split from `IMAPIdleReconnectTests` (the drop/backoff half) and
/// `IMAPIdleChannelTests` (what `IMAPSession` itself now permits) for the repo's
/// 500-line limit, the same way `IMAPAuthTests`/`IMAPAuthChannelTests` and
/// `IMAPProviderTests`/`IMAPProviderDeltaTests` were split.
///
/// **No test here sleeps a production duration.** The 29 minutes and the debounce
/// window both go through `IMAPIdleHarness.FakeClock`, which parks every sleep and
/// releases it on demand, so the numbers are asserted rather than waited for. See
/// that type for why the remaining 5 ms polls are cross-task progress and not a
/// clock.
@Suite struct IMAPIdleTests {

    // MARK: - Advertised, or the timer is the only trigger

    /// The negative half of the first criterion. A server that never says `IDLE`
    /// must get NO `IDLE`, and — the part that makes "the existing timer is the
    /// only trigger" true rather than merely claimed — no re-idle deadline is ever
    /// armed and no delta pass is ever requested.
    ///
    /// The script deliberately cannot answer a `SELECT`. A watcher that dropped the
    /// capability guard would issue one, get no answer, and be caught by the
    /// bounded outcome as well as by the byte assertions — two independent failures
    /// rather than a hang.
    @Test func idleIsNotEnteredWhenItIsNotAdvertised() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let recorder = IMAPIdleHarness.SyncRecorder()
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(capabilities: "IMAP4rev1",
                                   selectFixture: nil, doneCycles: 0),
        ])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: recorder.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }

        #expect(await IMAPIdleHarness.outcome(box) == .notAdvertised)
        let wire = await IMAPIdleHarness.wire(server)
        #expect(!wire.contains("IDLE"))
        // Not even the SELECT: the guard runs before the mailbox is chosen.
        #expect(!wire.contains("SELECT"))
        #expect(await clock.requested.isEmpty)
        #expect(await recorder.syncCount == 0)
        // The lease is released on the throwing path too — the leak Task 13 fixed.
        #expect(await server.isBalanced)
    }

    /// The positive contrast, without which the test above passes for any watcher
    /// that never idles at all. Same harness, same fixtures, one capability
    /// added.
    @Test func idleIsEnteredWhenItIsAdvertised() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }

        #expect(await IMAPIdleHarness.wire(server).contains("IDLE"))
        #expect(await watcher.connectionCount == 1)
        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// A mailbox list with nothing selectable is terminal, not a reconnect loop:
    /// retrying it on a schedule would be a connect that can never succeed.
    @Test func noSelectableMailboxIsTerminal() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(
            scripts: [IMAPIdleHarness.Script(selectFixture: nil, doneCycles: 0)],
            directory: try IMAPIdleHarness.noSelectableDirectory())
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        #expect(await IMAPIdleHarness.outcome(box) == .noSelectableMailbox)
        #expect(await clock.requested.isEmpty)
        #expect(await server.isBalanced)
    }

    // MARK: - 29 minutes, and DONE before anything else

    /// The re-idle deadline is exactly 29 minutes, asserted on the duration the
    /// production code *requests* rather than on elapsed time.
    ///
    /// `requested` is asserted as a whole list, not searched: a watcher that armed
    /// a 29-minute deadline alongside some other wait would pass a `contains` and
    /// fails here.
    @Test func reIdleDeadlineIsTwentyNineMinutes() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        // No `reIdleInterval:` argument: the default is the value under test.
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }

        #expect(await clock.requested == [.seconds(29 * 60)])
        #expect(await watcher.cycleCount == 0)

        // Expire it: one cycle completes and the next arms the same deadline.
        #expect(await clock.release(.seconds(29 * 60)))
        guard await IMAPIdleHarness.waitUntil("a second idle cycle", {
            await watcher.cycleCount == 1
        }) else { return }
        guard await IMAPIdleHarness.waitUntil("the second deadline", {
            await clock.requestCount(of: .seconds(29 * 60)) == 2
        }) else { return }
        #expect(await clock.requested == [.seconds(29 * 60), .seconds(29 * 60)])
        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// `DONE` is on the wire before any other command on that session — asserted on
    /// the recorded writes, as a whole list.
    ///
    /// Whole-list equality rather than "the DONE index is lower" is what makes this
    /// worth having: it pins that nothing at all was written between the `IDLE` and
    /// its `DONE`, that the `DONE` is bare and untagged, and that the second cycle's
    /// `IDLE` carries the NEXT tag — a watcher that reused `A0002` would be answered
    /// for a tag not in flight and torn down instead.
    @Test func doneIsWrittenBeforeTheNextCommandOnThatSession() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        #expect(await clock.release(.seconds(29 * 60)))
        guard await IMAPIdleHarness.waitUntil("the second IDLE to be written", {
            await clock.requestCount(of: .seconds(29 * 60)) == 2
        }) else { return }

        guard let connection = await server.connection(0) else { return }
        let writes = await connection.transport.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(writes == ["A0001 SELECT \"INBOX\"\r\n",
                           "A0002 IDLE\r\n",
                           "DONE\r\n",
                           "A0003 IDLE\r\n"])
        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// Three cycles in a row on ONE connection, each ended by its own deadline.
    ///
    /// A regression test for a real defect the two tests above found: cycle N's
    /// "the IDLE ended" task resumes on `idle.value` and then calls `wake`, and
    /// `cancel()` silences neither the await nor the call — so an unstamped wake
    /// from a finished cycle was delivered to the NEXT cycle's wait, which then
    /// skipped its `DONE` and awaited an `IDLE` that could never complete. The
    /// watcher hung on cycle two with the socket still open, which is
    /// indistinguishable from a quiet mailbox. Every cycle here therefore has to
    /// end because ITS OWN deadline expired, and `cycleCount` counts the `DONE`s
    /// that were actually acknowledged.
    @Test func consecutiveCyclesEachEndOnTheirOwnDeadline() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(doneCycles: 4),
        ])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }

        for cycle in 1...3 {
            guard await IMAPIdleHarness.waitUntil("deadline \(cycle)", {
                await clock.requestCount(of: .seconds(29 * 60)) == cycle
            }) else { return }
            #expect(await clock.release(.seconds(29 * 60)))
            guard await IMAPIdleHarness.waitUntil("cycle \(cycle) to complete", {
                await watcher.cycleCount == cycle
            }) else { return }
        }
        #expect(await watcher.cycleCount == 3)
        #expect(await watcher.connectionCount == 1)
        // Three DONEs, three re-IDLEs, all on the one connection.
        guard let connection = await server.connection(0) else { return }
        let writes = await connection.transport.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(writes == ["A0001 SELECT \"INBOX\"\r\n",
                           "A0002 IDLE\r\n", "DONE\r\n",
                           "A0003 IDLE\r\n", "DONE\r\n",
                           "A0004 IDLE\r\n", "DONE\r\n",
                           "A0005 IDLE\r\n"])
        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// `stop()` finishes the cycle rather than dropping the socket: the `DONE` goes
    /// out, the tagged completion is collected, and the lease is given back.
    @Test func stopSendsDoneAndReleasesTheLease() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }

        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
        #expect(await IMAPIdleHarness.wire(server).hasSuffix("DONE\r\n"))
        #expect(await watcher.cycleCount == 1)
        #expect(await server.isBalanced)
        // Nothing suspended behind the DONE: the IDLE's own waiter was resolved by
        // the tagged completion, not by the teardown.
        guard let connection = await server.connection(0) else { return }
        #expect(await connection.session.inFlightCount == 0)
    }

    // MARK: - What counts as a notification

    /// A `SELECT` reports its own `* n EXISTS`, and it is byte-identical to an
    /// arrival. `untaggedYieldCount` is what lets the watcher skip exactly the
    /// lines that already belonged to a command.
    ///
    /// The second half — an arrival enqueued afterwards IS counted — is what stops
    /// this passing for a watcher that never notices anything.
    @Test func selectsOwnExistsIsNotAnArrival() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let recorder = IMAPIdleHarness.SyncRecorder()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: recorder.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }

        // `imap-provider-select.txt` opens with `* 3 EXISTS`.
        #expect(await watcher.notificationCount == 0)
        #expect(await clock.requestCount(of: .seconds(1)) == 0)
        #expect(await recorder.syncCount == 0)

        guard let connection = await server.connection(0) else { return }
        await connection.transport.enqueue(
            try IMAPDeltaHarness.fixtureText("imap-idle-one-arrival"))
        guard await IMAPIdleHarness.waitUntil("the arrival to be noticed", {
            await watcher.notificationCount >= 1
        }) else { return }
        #expect(await watcher.notificationCount == 1)
        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// Untagged lines a server legitimately sends during an IDLE that are NOT
    /// arrivals — `* OK`, `* n RECENT`, `* FLAGS`, `* OK [UNSEEN n]` — must not
    /// trigger a pass.
    ///
    /// The noise and the arrival are enqueued as ONE blob, so the single read loop
    /// processes them strictly in order: once the arrival has been counted, all
    /// four noise lines have already been handled, and `== 1` cannot be a lucky
    /// early read.
    @Test func nonArrivalUntaggedLinesAreNotNotifications() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let recorder = IMAPIdleHarness.SyncRecorder()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: recorder.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        guard let connection = await server.connection(0) else { return }

        let noise = try IMAPDeltaHarness.fixtureText("imap-idle-noise")
        let arrival = try IMAPDeltaHarness.fixtureText("imap-idle-one-arrival")
        await connection.transport.enqueue(noise + arrival)
        guard await IMAPIdleHarness.waitUntil("the arrival behind the noise", {
            await watcher.notificationCount >= 1
        }) else { return }

        #expect(await watcher.notificationCount == 1)
        #expect(await clock.requestCount(of: .seconds(1)) == 1)
        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    // MARK: - Coalescing

    /// Ten notifications inside one window are ONE delta pass.
    ///
    /// Three assertions, and each one fails for a different broken watcher — which
    /// is the point, because a single "syncCount == 1" would also pass for a
    /// watcher that never syncs at all:
    ///
    /// 1. `notificationCount == 10` proves all ten really arrived *before* the
    ///    window closed. Without it "one sync" could just mean nine were dropped
    ///    on the floor by the transport.
    /// 2. `requestCount(of: 1s) == 1` proves ONE window was opened for the ten. A
    ///    watcher with no coalescing at all opens ten (or none, and syncs
    ///    immediately) — this is the assertion that a no-coalescing
    ///    implementation cannot satisfy.
    /// 3. `syncCount == 0` *while the window is still open*, then exactly 1 after
    ///    it is released. A watcher that fired on each notification is already at
    ///    10 before the release.
    ///
    /// The tail then proves the window really does re-open: a later arrival opens a
    /// second window and causes a second pass, so assertion 2 is not passing
    /// because windows are never opened.
    @Test func tenNotificationsInOneWindowCauseOneSync() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let recorder = IMAPIdleHarness.SyncRecorder()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        // The default one-second window is the value under test.
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: recorder.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        guard let connection = await server.connection(0) else { return }

        // Ten notification lines in one write — the burst a busy mailbox produces.
        await connection.transport.enqueue(
            try IMAPDeltaHarness.fixtureText("imap-idle-burst"))
        guard await IMAPIdleHarness.waitUntil("all ten notifications", {
            await watcher.notificationCount == 10
        }) else { return }

        #expect(await watcher.notificationCount == 10)
        #expect(await clock.requestCount(of: .seconds(1)) == 1)
        #expect(await recorder.syncCount == 0)

        #expect(await clock.release(.seconds(1)))
        guard await IMAPIdleHarness.waitUntil("the coalesced pass", {
            await recorder.syncCount == 1
        }) else { return }
        #expect(await recorder.syncCount == 1)
        // The flush did not re-arm a window it had nothing left to coalesce.
        #expect(await clock.requestCount(of: .seconds(1)) == 1)

        // A LATER arrival opens a NEW window, so "one window" above is a property
        // of the burst and not of a watcher that opens none.
        await connection.transport.enqueue(
            try IMAPDeltaHarness.fixtureText("imap-idle-one-arrival"))
        guard await IMAPIdleHarness.waitUntil("a second window", {
            await clock.requestCount(of: .seconds(1)) == 2
        }) else { return }
        #expect(await clock.release(.seconds(1)))
        guard await IMAPIdleHarness.waitUntil("the second pass", {
            await recorder.syncCount == 2
        }) else { return }
        #expect(await recorder.syncCount == 2)
        #expect(await watcher.notificationCount == 11)

        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }

    /// A notification arriving *while* the coalesced pass runs opens a new window
    /// rather than being swallowed by the one that is finishing.
    ///
    /// This is the difference between clearing `pendingSync` before the pass and
    /// after it, and it is the shape that loses a real arrival: the pass reads the
    /// mailbox as it was, and the message that landed a millisecond later would
    /// wait out the poll interval.
    @Test func aNotificationDuringThePassOpensANewWindow() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script()])
        let gate = IMAPIdleHarness.GatedRecorder()
        let watcher = IMAPIdleWatcher(provider: IMAPIdleHarness.provider(server),
                                      clock: clock, onNotification: gate.trigger)
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        guard let connection = await server.connection(0) else { return }
        let arrival = try IMAPDeltaHarness.fixtureText("imap-idle-one-arrival")

        await connection.transport.enqueue(arrival)
        guard await IMAPIdleHarness.waitUntil("the first window", {
            await clock.requestCount(of: .seconds(1)) == 1
        }) else { return }
        #expect(await clock.release(.seconds(1)))
        // The pass is now suspended inside `onNotification`.
        guard await IMAPIdleHarness.waitUntil("the pass to start", {
            await gate.started == 1
        }) else { return }

        await connection.transport.enqueue(arrival)
        guard await IMAPIdleHarness.waitUntil("a window opened during the pass", {
            await clock.requestCount(of: .seconds(1)) == 2
        }) else { return }
        await gate.open()
        #expect(await clock.release(.seconds(1)))
        guard await IMAPIdleHarness.waitUntil("the second pass", {
            await gate.started == 2
        }) else { return }
        #expect(await gate.started == 2)

        await gate.open()
        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }
}
