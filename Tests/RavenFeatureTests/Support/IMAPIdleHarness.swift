import Testing
import Foundation
@testable import RavenFeature

/// The scripted IDLE server, the fake clock, and the bounded waits that
/// `IMAPIdleTests`, `IMAPIdleReconnectTests` and `IMAPIdleChannelTests` share.
///
/// Split into its own file for the repo's line limit, and for the same reason
/// `IMAPDeltaHarness` was: the three suites must drive the **same** scripted
/// server. A re-idle asserted against one server shape and a reconnect asserted
/// against another prove nothing about each other, and the whole point of
/// `IMAPIdleWatcher` is that one connection's cycles and the reconnect that
/// follows them are the same state machine.
///
/// ## Every wait here is bounded, and no wait is a real-time sleep of a
/// production duration
///
/// The two numbers Task 14 exists to get right are a **29-minute** re-idle and a
/// **doubling backoff**. Neither is observable by waiting, so `IMAPIdleClock` is
/// injected and `FakeClock` below records the *requested* durations and releases
/// them on demand. What remains is cross-task progress — "has the watcher reached
/// its idle wait yet" — which is polled in 5 ms steps up to a 5 s ceiling. A
/// condition that never becomes true therefore records an `Issue` rather than
/// hanging the suite, which matters more here than almost anywhere: the defect
/// class this file guards against (a `Wake` nobody delivers, a `DONE` nobody
/// writes) presents as a hang, and a hung run reports as an infrastructure
/// timeout instead of as the bug it is.
enum IMAPIdleHarness {

    // MARK: - The injected clock

    /// An `IMAPIdleClock` that never advances on its own.
    ///
    /// Sleeps are recorded in request order and parked until a test releases one
    /// **by its exact duration**, which is what makes "29 minutes" and "1 s, then
    /// 2 s" assertions rather than waits. Releasing by duration rather than by
    /// index is deliberate: a cycle has a re-idle deadline pending while a
    /// debounce window may also be open, and an index-based release would silently
    /// resume the wrong one when the production code changed order.
    ///
    /// Cancellation is honoured, because the production code depends on it: a
    /// cycle cancels its deadline task the moment something else wakes it, and a
    /// clock that left those sleeps parked forever would leak one continuation per
    /// cycle and make a 29-minute assertion pass for the wrong reason.
    actor FakeClock: IMAPIdleClock {
        private struct Parked {
            let id: Int
            let duration: Duration
        }

        private var nextID = 0
        private var open: [Parked] = []
        private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        /// Sleeps cancelled before their continuation was registered.
        private var cancelledEarly: Set<Int> = []

        /// Every duration ever requested, in order. The re-idle and backoff
        /// assertions read this.
        private(set) var requested: [Duration] = []

        /// Durations currently parked, in request order.
        var pending: [Duration] { open.map(\.duration) }
        /// How many sleeps of exactly `duration` have ever been requested — the
        /// coalescing assertion's "one window, not ten".
        func requestCount(of duration: Duration) -> Int {
            requested.filter { $0 == duration }.count
        }

        func sleep(for duration: Duration) async throws {
            nextID += 1
            let id = nextID
            requested.append(duration)
            open.append(Parked(id: id, duration: duration))
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    // Still actor-isolated and no await since the append above, so
                    // a cancellation cannot slip in unobserved between the two.
                    if cancelledEarly.remove(id) != nil {
                        forget(id)
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelSleep(id) }
            }
        }

        /// Resumes the OLDEST parked sleep of exactly `duration`. Returns false if
        /// there is none, so a caller can poll rather than guess.
        @discardableResult
        func release(_ duration: Duration) -> Bool {
            guard let entry = open.first(where: { $0.duration == duration }),
                  let continuation = waiters.removeValue(forKey: entry.id) else { return false }
            forget(entry.id)
            continuation.resume()
            return true
        }

        private func cancelSleep(_ id: Int) {
            if let continuation = waiters.removeValue(forKey: id) {
                forget(id)
                continuation.resume(throwing: CancellationError())
            } else if open.contains(where: { $0.id == id }) {
                cancelledEarly.insert(id)
            }
        }

        private func forget(_ id: Int) { open.removeAll { $0.id == id } }
    }

    // MARK: - The scripted server

    /// One IMAP connection's script.
    ///
    /// `doneCycles` is the number of `IDLE`→`DONE` cycles the server will complete
    /// on this connection. It is a *count* rather than "repeatable", because each
    /// cycle's tagged completion carries a different tag: a repeatable rule would
    /// answer every `DONE` with cycle one's tag, `handleTagged` would see an
    /// unknown tag and tear the session down, and the reconnect that followed
    /// would look like the drop the test was trying to script.
    struct Script: Sendable {
        var capabilities: String = "IMAP4rev1 IDLE"
        /// The fixture a `SELECT` is answered with, or nil for a connection that
        /// never selects (the user-action session).
        var selectFixture: String? = "imap-provider-select"
        var doneCycles: Int = 2
        /// Extra rules, answered after the ones above. `%TAG%` in a response is
        /// replaced with the tag the session will actually have used by then.
        var extra: [Rule] = []

        struct Rule: Sendable {
            let needle: String
            let response: String
            init(_ needle: String, _ response: String) {
                self.needle = needle
                self.response = response
            }
        }
    }

    struct Connection: Sendable {
        let session: IMAPSession
        let transport: ScriptedTransport
    }

    enum HarnessError: Error, Equatable { case noScriptLeft }

    /// Hands out one scripted connection per lease, in script order, and counts
    /// the leases.
    ///
    /// The acquire/release balance is the only thing that can catch a bypassed
    /// lease: a scripted session behaves identically whether or not it was handed
    /// back, so nothing about the recorded bytes would change. Same reason
    /// `IMAPProviderHarness.LeaseRecorder` exists — but here the recorder must
    /// also *build* each connection, because a reconnect is a new socket and
    /// reusing one session across drops would make `connectionCount` a fiction.
    actor Server {
        private var scripts: [Script]
        /// The account's mailboxes. Overridable so "no selectable mailbox" is
        /// reachable without a second server type.
        private let directory: IMAPMailboxDirectory?
        private(set) var connections: [Connection] = []
        private(set) var acquired = 0
        private(set) var released = 0
        private(set) var acquireFailures = 0
        /// When true, `release` runs the REAL production teardown
        /// (`IMAPProvider.closeSession`, i.e. `LOGOUT` then close) instead of a
        /// bare close, so a suite can assert what production does to an IDLE
        /// connection between cycles. The script must then answer `LOGOUT`.
        private let productionTeardown: Bool

        /// Acquires parked at the gate, plus whether the gate is shut.
        ///
        /// With `gateAcquire: true` the FIRST thing `acquire` does is suspend, which
        /// makes "the watcher's run has started but its outcome is not yet decided"
        /// a state a test can hold indefinitely. That window is where a sign-out
        /// races a terminal outcome, and without the gate the race is real-time and
        /// therefore flaky in both directions.
        private var acquireGate: [CheckedContinuation<Void, Never>] = []
        private var gateShut: Bool
        /// Acquires ENTERED, whether or not they were granted — unlike `acquired`,
        /// which counts leases handed out.
        private(set) var acquireAttempts = 0

        init(scripts: [Script],
             directory: IMAPMailboxDirectory? = nil,
             productionTeardown: Bool = false,
             gateAcquire: Bool = false) {
            self.scripts = scripts
            self.directory = directory
            self.productionTeardown = productionTeardown
            self.gateShut = gateAcquire
        }

        /// Lets every parked acquire — and every later one — through.
        func openAcquireGate() {
            gateShut = false
            let parked = acquireGate
            acquireGate = []
            for continuation in parked { continuation.resume() }
        }

        var isBalanced: Bool { acquired == released && acquired > 0 }
        var connectionCount: Int { connections.count }

        func connection(_ index: Int) -> Connection? {
            index < connections.count ? connections[index] : nil
        }

        func acquire() async throws -> IMAPSessionLease {
            acquireAttempts += 1
            if gateShut {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    acquireGate.append(continuation)
                }
            }
            guard !scripts.isEmpty else {
                acquireFailures += 1
                throw HarnessError.noScriptLeft
            }
            let script = scripts.removeFirst()
            let connection = try await IMAPIdleHarness.connection(script)
            connections.append(connection)
            acquired += 1
            let working = IMAPWorkingSession(
                session: connection.session,
                directory: try directory ?? IMAPProviderHarness.directory())
            let teardown = productionTeardown
            return IMAPSessionLease(working: working) { [weak self] in
                if teardown {
                    await IMAPProvider.closeSession(working)
                } else {
                    await working.session.close()
                }
                await self?.noteReleased()
            }
        }

        private func noteReleased() { released += 1 }
    }

    /// A connected session over a transport scripted per `script`.
    ///
    /// Capabilities arrive in the greeting, so no `CAPABILITY` command is issued
    /// and the tags are exactly `A0001…` in the order the client sends its
    /// commands — which makes the tag in each scripted answer an assertion in
    /// itself. A watcher that issued its commands in a different order gets a
    /// completion for a tag that is not in flight, the session tears down, and the
    /// bounded waits below report it instead of a plausible-looking pass.
    static func connection(_ script: Script) async throws -> Connection {
        let transport = ScriptedTransport(idleReads: .suspend)
        await transport.enqueue("* OK [CAPABILITY \(script.capabilities)] ready\r\n")
        var tagCounter = 0
        func nextTag() -> String {
            tagCounter += 1
            return String(format: "A%04d", tagCounter)
        }
        if let fixture = script.selectFixture {
            let body = try IMAPDeltaHarness.fixtureText(fixture)
            await transport.respond(to: "SELECT",
                                    with: body + "\(nextTag()) OK [READ-WRITE] selected\r\n")
        }
        // The `+ idling` carries no tag, so this one is repeatable.
        await transport.respond(to: "IDLE", with: "+ idling\r\n", repeatable: true)
        for _ in 0..<script.doneCycles {
            await transport.respond(to: "DONE", with: "\(nextTag()) OK IDLE terminated\r\n")
        }
        for rule in script.extra {
            await transport.respond(to: rule.needle,
                                    with: rule.response.replacingOccurrences(
                                        of: "%TAG%", with: nextTag()))
        }
        let session = IMAPSession(transport: transport)
        try await session.connect()
        return Connection(session: session, transport: transport)
    }

    /// A provider whose only route to a session is `Server.acquire`.
    static func provider(_ server: Server) -> IMAPProvider {
        IMAPProvider(accountID: IMAPProviderHarness.accountID) {
            try await server.acquire()
        }
    }

    /// A directory whose only mailbox is a `\Noselect` container — an account that
    /// exists but has nothing to idle on.
    static func noSelectableDirectory() throws -> IMAPMailboxDirectory {
        IMAPMailboxDirectory(untagged: try IMAPFetchWire.untaggedResponses(
            Data("* LIST (\\Noselect \\HasChildren) \"/\" \"Folder D\"\r\n".utf8)))
    }

    // MARK: - What a notification triggered

    /// Counts the delta passes the watcher asked for, and holds a cursor it is
    /// never given a way to touch.
    ///
    /// The count is the whole coalescing assertion. The cursor is here so
    /// "reconnecting never loses it" has something to be about at this layer:
    /// the watcher's only output is "run a pass", so the property it can break is
    /// *whether* a pass runs (an arrival seen before a drop must still cause one,
    /// and a bare reconnect must cause none), not what the pass does to the
    /// cursor — that half is Task 12's, asserted in `IMAPDeltaStrategyTests`.
    actor SyncRecorder {
        private(set) var syncCount = 0
        private(set) var cursor: IMAPSyncCursor

        init(cursor: IMAPSyncCursor = IMAPDeltaHarness.storedCursor()) {
            self.cursor = cursor
        }

        func note() { syncCount += 1 }
        /// The closure handed to `IMAPIdleWatcher.onNotification`.
        nonisolated var trigger: @Sendable () async -> Void {
            { await self.note() }
        }
    }

    /// A delta pass that SUSPENDS until the test lets it finish.
    ///
    /// Needed for exactly one property: `flush` clears `pendingSync` *before* the
    /// pass runs, so a notification arriving mid-pass opens a new window instead of
    /// being swallowed. That is only observable while a pass is in flight, and a
    /// pass that returns immediately is never in flight for long enough to enqueue
    /// anything against.
    actor GatedRecorder {
        private(set) var started = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// `open()` calls that arrived before the pass they release.
        private var credits = 0

        func run() async {
            started += 1
            if credits > 0 {
                credits -= 1
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }

        /// Lets one suspended pass (or the next one to start) return.
        func open() {
            if waiters.isEmpty {
                credits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }

        nonisolated var trigger: @Sendable () async -> Void { { await self.run() } }
    }

    // MARK: - Running a watcher

    /// A `run()` in flight, plus its outcome once it finishes.
    actor RunBox {
        private(set) var outcome: IMAPIdleWatcher.Outcome?
        func set(_ value: IMAPIdleWatcher.Outcome) { if outcome == nil { outcome = value } }
    }

    /// Starts `run()` in its own task. Returns the task so a test can cancel it
    /// (the cancellation path is itself under test) and the box so it can await
    /// the outcome with a deadline.
    static func start(_ watcher: IMAPIdleWatcher) -> (Task<Void, Never>, RunBox) {
        let box = RunBox()
        let task = Task { await box.set(await watcher.run()) }
        return (task, box)
    }

    /// Waits for `run()` to finish, bounded, and returns its outcome.
    static func outcome(_ box: RunBox, sourceLocation: SourceLocation = #_sourceLocation) async
        -> IMAPIdleWatcher.Outcome? {
        guard await waitUntil("run() to finish", sourceLocation: sourceLocation, {
            await box.outcome != nil
        }) else { return nil }
        return await box.outcome
    }

    // MARK: - Bounded waits

    /// Polls `condition` in 5 ms steps for up to 5 s. Records an `Issue` and
    /// returns false on expiry, so a stalled watcher fails the test rather than
    /// hanging the run.
    ///
    /// The 5 ms are real, and they are not a production duration: every duration
    /// the production code waits on goes through `FakeClock` and is released
    /// explicitly. This polls for *cross-task progress* only, the same way
    /// `IMAPSessionHarness.waitForInFlight` and `IMAPProviderHarness.outcome` do.
    @discardableResult
    static func waitUntil(_ label: String,
                          sourceLocation: SourceLocation = #_sourceLocation,
                          _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(label)", sourceLocation: sourceLocation)
        return false
    }

    /// `waitUntil` for a condition over `@MainActor` state — `RavenRuntime`'s
    /// `pushStates`/`syncErrors`, which the `@Sendable` variant above cannot touch
    /// at all.
    @discardableResult
    static func waitUntilOnMain(_ label: String,
                                sourceLocation: SourceLocation = #_sourceLocation,
                                _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(label)", sourceLocation: sourceLocation)
        return false
    }

    /// Waits until a sleep of exactly `duration` is parked on the clock.
    ///
    /// This is how a test knows the watcher has reached its idle wait: the
    /// deadline sleep is requested as part of entering the wait, so its presence
    /// is the synchronisation point, and its duration is the assertion.
    @discardableResult
    static func waitForSleep(_ clock: FakeClock, _ duration: Duration,
                             sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await waitUntil("a parked sleep of \(duration)", sourceLocation: sourceLocation) {
            await clock.pending.contains(duration)
        }
    }

    /// Waits until the watcher is idling on connection `index + 1`: the `IDLE`
    /// command has been written and the re-idle deadline is parked.
    @discardableResult
    static func waitUntilIdling(_ server: Server, _ clock: FakeClock,
                                connection index: Int = 0,
                                reIdle: Duration = .seconds(29 * 60),
                                sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        guard await waitUntil("connection \(index + 1)", sourceLocation: sourceLocation, {
            await server.connectionCount > index
        }) else { return false }
        guard let connection = await server.connection(index) else { return false }
        guard await waitUntil("an IDLE on connection \(index + 1)",
                              sourceLocation: sourceLocation, {
            await connection.transport.sentText.contains("IDLE")
        }) else { return false }
        return await waitForSleep(clock, reIdle, sourceLocation: sourceLocation)
    }

    /// The bytes one connection has seen, for the ordering assertions.
    static func wire(_ server: Server, _ index: Int = 0) async -> String {
        guard let connection = await server.connection(index) else { return "" }
        return await connection.transport.sentText
    }
}
