import Foundation

/// Where IDLE's two waits come from.
///
/// Injected, not read from the wall clock, and that is a testability requirement
/// rather than a style preference: the two numbers this file exists to get right
/// are a **29-minute** re-idle deadline and a **doubling reconnect backoff**, and
/// neither is assertable if the only way to observe it is to wait for it. With the
/// clock injected, a test asserts the *requested* durations exactly and releases
/// them on demand, so no test sleeps for real time and no test is flaky because a
/// loaded machine took 30 ms longer than the assertion allowed.
///
/// There is deliberately no jitter anywhere in this file. Jitter would protect a
/// server from a thundering herd of clients; this is a personal client with a
/// handful of accounts, and a `random`-seeded schedule is exactly the
/// nondeterminism that turns a real backoff regression into an intermittent
/// failure nobody trusts. The schedule is a pure function of the attempt number.
protocol IMAPIdleClock: Sendable {
    /// Suspends for `duration`. Throws `CancellationError` if the calling task is
    /// cancelled while suspended.
    func sleep(for duration: Duration) async throws
}

/// The production clock: `Task.sleep`, which is already cancellation-aware.
struct IMAPIdleSystemClock: IMAPIdleClock {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// The reconnect schedule: `first`, doubling, capped at `ceiling`.
///
/// A value type with a pure `delay(attempt:)` so the whole schedule can be
/// asserted without running a single reconnect.
struct IMAPIdleBackoff: Sendable, Equatable {
    let first: Duration
    let ceiling: Duration

    init(first: Duration = .seconds(1), ceiling: Duration = .seconds(120)) {
        self.first = first
        self.ceiling = ceiling
    }

    /// `attempt` counts from 1. Doubling is done on the *attempt exponent* rather
    /// than by mutating a stored value, so a schedule that was reset and one that
    /// never advanced are the same value rather than two states to keep in step.
    func delay(attempt: Int) -> Duration {
        guard attempt > 1 else { return min(first, ceiling) }
        // Capped at 2^20 before the multiply, so a long-lived watcher against a
        // permanently dead server cannot overflow the multiplication instead of
        // saturating at `ceiling`.
        let factor = Int64(1) << Int64(min(attempt - 1, 20))
        let scaled = first * Double(factor)
        return min(scaled, ceiling)
    }
}

/// Why an IDLE run ended, when it ended for a reason that is not "the caller
/// stopped it".
enum IMAPIdleError: Error, Equatable {
    /// The server never advertised `IDLE`. Not retried: the existing poll timer is
    /// the only trigger for this account, which is exactly the fallback.
    case notAdvertised
    /// The account has no selectable mailbox, so there is nothing to idle on.
    case noSelectableMailbox
}

/// Near-push arrival for an IMAP account: one long-lived `IDLE` connection whose
/// unsolicited `EXISTS`/`FETCH`/`EXPUNGE` notifications trigger the ordinary delta
/// pass, **in addition to** the 120-second poll in `RavenRuntime+Sync.swift` and
/// never instead of it.
///
/// ## Its own session, and why that settles the router question
///
/// The watcher takes a lease of its own and holds it for the life of one IDLE
/// connection. That is not merely so a user action is not blocked waiting for
/// `DONE` (though it is that too — a `FETCH` issued while this session idles would
/// be refused by `requireChannelAdmits`, since IDLE is exclusive). It is also what
/// keeps `IMAPSession`'s untagged attribution honest without a mailbox-scoped
/// response router: IDLE is the *only* command in flight on this session, and every
/// FETCH runs on a different session where it is likewise sole, so
/// `inFlight.count == 1` holds on both and neither one's untagged data can be
/// misfiled as the other's.
///
/// ## The lease was already the right shape
///
/// `IMAPProvider.withSession` is still the only route to a session here, and it did
/// not have to be extended. It expresses "a session for the duration of ONE
/// operation, released on both the success and the throwing path", and an IDLE
/// connection *is* one operation — a long one. A drop, a cancel and a 29-minute
/// re-idle all end that operation, `withSession` logs out and closes, and the
/// reconnect loop below asks for a new lease. Holding a session across reconnects
/// would have needed a new lifetime shape; holding it across *cycles of one
/// connection* does not.
///
/// ## Coalescing
///
/// Notifications set a pending flag and start ONE debounce window; every further
/// notification inside that window lands on the same flag. Ten notifications in a
/// second are therefore one delta pass, not ten — and the count matters, because a
/// delta pass walks every mailbox and ten of them back to back is a self-inflicted
/// rate limit.
///
/// ## The cursor
///
/// Nothing here touches it. The watcher's only output is "run a delta pass", and
/// the pass owns the cursor with Task 12's discipline (hold, do not advance, on a
/// partial pass). What the watcher must not do is *lose* a notification: a pending
/// flag set before a drop survives the reconnect, so an arrival seen on a
/// connection that then died is still synced rather than waiting for the poll.
actor IMAPIdleWatcher {

    /// How a run finished. Returned rather than logged so a test asserts it.
    enum Outcome: Sendable, Equatable {
        /// `IDLE` was not advertised; the poll timer is this account's only trigger.
        case notAdvertised
        /// `stop()` was called, or the task was cancelled.
        case stopped
        /// The account has no mailbox that can be `SELECT`ed.
        case noSelectableMailbox
    }

    /// What woke a cycle out of its idle wait.
    private enum Wake: Sendable, Equatable {
        /// The re-idle deadline expired.
        case deadline
        /// The IDLE command itself finished — a dropped connection, or a server
        /// that ended the idle on its own.
        case ended
        /// `stop()`, or task cancellation.
        case stopped
    }

    /// Keywords that mean "something changed in the selected mailbox".
    /// `EXPUNGE` is in the set with the other two because a removal is as much a
    /// reason to re-walk as an arrival; a mailbox that only ever expunges would
    /// otherwise wait out the poll interval.
    private static let notificationKeywords: Set<String> = ["EXISTS", "FETCH", "EXPUNGE"]

    private let provider: IMAPProvider
    private let clock: any IMAPIdleClock
    private let reIdleInterval: Duration
    private let coalesceWindow: Duration
    private let backoff: IMAPIdleBackoff
    private let onNotification: @Sendable () async -> Void

    private var stopped = false
    private var waiter: CheckedContinuation<Wake, Never>?
    private var pendingSync = false
    private var debounce: Task<Void, Never>?
    /// Monotonic cycle number, used to stamp the wakes a cycle arms so a stale one
    /// cannot resume its successor's wait. See `oneCycle`.
    private var cycleGeneration = 0
    /// True once this connection has completed at least one full idle cycle, so a
    /// later drop restarts the backoff schedule from `first` instead of continuing
    /// to double against a server that is plainly reachable.
    private var idledSinceReconnect = false

    // MARK: Introspection (assertions read these)

    /// Notifications observed, before coalescing. The coalescing assertion needs
    /// both this and the sync count: "ten in, one out" is only meaningful if the
    /// test can prove all ten arrived before the window closed.
    private(set) var notificationCount = 0
    /// Completed `IDLE`/`DONE` cycles on the current and previous connections.
    private(set) var cycleCount = 0
    /// Leases taken — one per connection, so a reconnect is visible.
    private(set) var connectionCount = 0
    /// Every backoff delay actually waited, in order.
    private(set) var backoffDelays: [Duration] = []

    init(provider: IMAPProvider,
         clock: any IMAPIdleClock = IMAPIdleSystemClock(),
         reIdleInterval: Duration = .seconds(29 * 60),
         coalesceWindow: Duration = .seconds(1),
         backoff: IMAPIdleBackoff = IMAPIdleBackoff(),
         onNotification: @escaping @Sendable () async -> Void) {
        self.provider = provider
        self.clock = clock
        self.reIdleInterval = reIdleInterval
        self.coalesceWindow = coalesceWindow
        self.backoff = backoff
        self.onNotification = onNotification
    }

    // MARK: - Running

    /// Idles until stopped, reconnecting with backoff after a drop.
    ///
    /// `notAdvertised` and `noSelectableMailbox` are terminal: neither is a
    /// transient condition, and retrying either on a schedule would be a
    /// reconnect loop that can never succeed.
    func run() async -> Outcome {
        var attempt = 0
        while !stopped {
            idledSinceReconnect = false
            do {
                try await runOneConnection()
            } catch let error as IMAPIdleError {
                switch error {
                case .notAdvertised: return .notAdvertised
                case .noSelectableMailbox: return .noSelectableMailbox
                }
            } catch {
                if stopped { break }
                attempt = idledSinceReconnect ? 1 : attempt + 1
                let delay = backoff.delay(attempt: attempt)
                backoffDelays.append(delay)
                do { try await clock.sleep(for: delay) } catch { break }
            }
        }
        return .stopped
    }

    /// Stops after the current cycle: the `DONE` still goes out and the lease is
    /// still released, so the connection is not simply dropped on the server.
    func stop() {
        stopped = true
        debounce?.cancel()
        debounce = nil
        wake(.stopped)
    }

    /// One connection: select, then idle in cycles until it ends.
    private func runOneConnection() async throws {
        connectionCount += 1
        try await provider.withSession { working in
            guard await working.session.hasCapability("IDLE") else {
                throw IMAPIdleError.notAdvertised
            }
            guard let mailbox = IMAPProvider.walkable(working.directory).first else {
                throw IMAPIdleError.noSelectableMailbox
            }
            try await working.session.execute(
                IMAPCommand("SELECT", [.text(mailbox.name)], isExclusive: true))
            // Everything yielded so far — the authentication's untagged lines, the
            // `LIST`, and this `SELECT`'s own `* n EXISTS` — belongs to a command,
            // not to an arrival. Skipping exactly that many is what stops a
            // `SELECT` from looking like a notification and firing a sync on every
            // single connection.
            let alreadyYielded = await working.session.untaggedYieldCount
            let stream = working.session.untaggedResponses
            let consumer = Task { await self.consume(stream, skipping: alreadyYielded) }
            defer { consumer.cancel() }
            while !(await self.stopped) {
                try await self.oneCycle(on: working.session)
            }
        }
    }

    /// `IDLE` → wait → `DONE` → the tagged completion.
    ///
    /// The `DONE` is written before this returns, so the next command issued on this
    /// session — the next cycle's `IDLE` — is always preceded by it on the wire.
    /// That is not a convention: `IMAPSession.requireChannelAdmits` refuses any
    /// second command while an exclusive one is in flight, so a command that jumped
    /// the `DONE` would throw rather than reach the server.
    private func oneCycle(on session: IMAPSession) async throws {
        // Which cycle this is. Every wake a cycle arms is stamped with it, because
        // `cancel()` is not enough to silence one: `ended` waits on `idle.value`
        // and then calls `wake`, and neither the await nor the call checks
        // cancellation, so cycle N's `ended` legitimately resumes *after* cycle N+1
        // has registered its waiter. Unstamped, it delivered `.ended` to the next
        // cycle, which skipped that cycle's `DONE` and awaited an `IDLE` that could
        // therefore never complete — the watcher hung on cycle two, silently, with
        // the connection still open. Found by `reIdleDeadlineIsTwentyNineMinutes`
        // and `doneIsWrittenBeforeTheNextCommandOnThatSession`, which are the first
        // tests to run more than one cycle.
        cycleGeneration += 1
        let generation = cycleGeneration
        let idle = Task { try await session.execute(
            IMAPCommand("IDLE", isExclusive: true, holdsChannelOpen: true)) }
        // Whichever of these happens first wins; the other two are cancelled.
        let ended = Task { [weak self] in
            _ = try? await idle.value
            await self?.wake(.ended, generation: generation)
        }
        let deadline = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(for: self.reIdleInterval) } catch { return }
            await self.wake(.deadline, generation: generation)
        }
        let wake = await withTaskCancellationHandler {
            await awaitWake()
        } onCancel: {
            Task { await self.stop() }
        }
        deadline.cancel()
        ended.cancel()
        if wake == .ended {
            // The connection is gone: `DONE` cannot be delivered and the real
            // failure is the one the command itself carries. Surfacing that rather
            // than a synthesised "DONE with no IDLE in flight" is what makes the
            // reconnect log say why.
            _ = try await idle.value
            return
        }
        try await session.sendIdleDone()
        _ = try await idle.value
        cycleCount += 1
        idledSinceReconnect = true
    }

    // MARK: - The idle wait

    /// Suspends until something wakes the cycle. Deliberately non-throwing: a
    /// cycle's outcome is decided by the `Wake`, so there is no path where this
    /// resumes with an error and leaves the caller unsure whether `DONE` is owed.
    private func awaitWake() async -> Wake {
        if stopped { return .stopped }
        return await withCheckedContinuation { continuation in
            if stopped {
                continuation.resume(returning: .stopped)
            } else {
                // A previous cycle cannot have left a waiter behind: `wake` clears
                // it before resuming, and only one cycle runs at a time.
                waiter = continuation
            }
        }
    }

    /// Resumes the current wait, if there is one. Nothing is parked: a `deadline`
    /// or `ended` that arrives with no waiter belongs to a cycle that has already
    /// moved on, and a notification does NOT wake the cycle at all — it goes to the
    /// debouncer, which is independent of the idle loop.
    ///
    /// - Parameter generation: the cycle that armed this wake, or nil for one that
    ///   belongs to the watcher rather than to a cycle (`stop()`, which must reach
    ///   whichever cycle is current). A stamped wake from a cycle that has already
    ///   finished is dropped rather than delivered to its successor — see
    ///   `oneCycle`, where the absence of this check hung the second cycle.
    private func wake(_ reason: Wake, generation: Int? = nil) {
        if let generation, generation != cycleGeneration { return }
        guard let continuation = waiter else { return }
        waiter = nil
        continuation.resume(returning: reason)
    }

    // MARK: - Notifications and coalescing

    private func consume(_ stream: AsyncStream<IMAPUntaggedResponse>, skipping: Int) async {
        var skipped = 0
        for await response in stream {
            if skipped < skipping {
                skipped += 1
                continue
            }
            guard let keyword = response.keyword,
                  Self.notificationKeywords.contains(keyword) else { continue }
            note()
        }
    }

    /// One notification. Sets the pending flag and starts the debounce window if it
    /// is not already open, so a burst collapses onto ONE delta pass.
    ///
    /// The pending flag is deliberately a flag and not a queue: "how many
    /// notifications arrived" is not information a delta pass can use — it walks
    /// from the stored cursor either way — so counting them would only produce
    /// duplicate passes.
    private func note() {
        notificationCount += 1
        pendingSync = true
        guard debounce == nil else { return }
        debounce = Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: self.coalesceWindow)
            await self.flush()
        }
    }

    /// Runs the coalesced delta pass, if one is still owed.
    ///
    /// `pendingSync` is cleared BEFORE the pass runs, so a notification arriving
    /// *during* the pass opens a new window rather than being swallowed by this one.
    /// The flag also survives a dropped connection untouched: `runOneConnection`
    /// never clears it, so an arrival seen just before a drop is still synced after
    /// the reconnect instead of waiting out the poll interval.
    private func flush() async {
        debounce = nil
        guard pendingSync else { return }
        pendingSync = false
        await onNotification()
    }
}
