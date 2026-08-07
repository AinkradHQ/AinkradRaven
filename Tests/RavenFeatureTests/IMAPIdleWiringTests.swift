import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Task 14's last mile: `IMAPIdleWatcher` reachable from a running `RavenRuntime`.
///
/// The watcher's own state machine is covered by `IMAPIdleTests`,
/// `IMAPIdleReconnectTests` and `IMAPIdleChannelTests`. This file only asserts the
/// things that are true of the RUNTIME: that an IMAP account gets exactly one
/// watcher and no other kind gets any, that an IDLE notification reaches the same
/// per-account delta pass the poll timer reaches, that the timer still covers an
/// account IDLE cannot serve, and that signing out or tearing down actually gives
/// the socket back.
///
/// Every runtime here calls `teardown()` immediately after `init` — the convention
/// `MultiAccountTests` established — so the real 120-second poll loop cannot race
/// a manual tick. The IDLE clock is replaced through `idleClockOverride`, so the
/// one-second coalesce window is released on demand rather than slept through.
@Suite("IDLE wiring into the runtime", .timeLimit(.minutes(1)))
@MainActor struct IMAPIdleWiringTests {

    /// A torn-down runtime (no live poll loop) with a fake IDLE clock installed.
    private func runtime(_ clock: IMAPIdleHarness.FakeClock) -> RavenRuntime {
        let runtime = RavenRuntime(host: FakeHostServices())
        runtime.teardown()
        runtime.idleClockOverride = clock
        return runtime
    }

    /// An IMAP account row. No `syncCursor`, so a delta pass takes the backfill
    /// path and reaches the provider either way — what matters is only that it
    /// reaches the provider at all.
    private func imapAccount(_ id: String) -> MailAccount {
        MailAccount(id: id, provider: .imap, address: "\(id)@example.test",
                    displayName: id, state: .ready)
    }

    /// One scripted IMAP server whose FIRST lease idles and whose SECOND lease
    /// fails with `noScriptLeft`.
    ///
    /// That failure is the marker the delta-pass assertions read: it is distinctive,
    /// it can only come from a lease this account's provider actually took, and it
    /// cannot be produced by the runtime on its own. A pass that never reached the
    /// provider leaves `syncErrors` nil, which is exactly the negative case.
    private func idlingServer(capabilities: String = "IMAP4rev1 IDLE")
        -> IMAPIdleHarness.Server {
        IMAPIdleHarness.Server(scripts: [IMAPIdleHarness.Script(capabilities: capabilities)])
    }

    // MARK: - Who gets a watcher

    @Test("an IMAP account gets exactly one IDLE watcher")
    func anIMAPAccountGetsAWatcher() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = idlingServer()
        try runtime.store.saveAccount(imapAccount("a-imap"))
        runtime.attach(provider: IMAPIdleHarness.provider(server), accountID: "a-imap")

        #expect(runtime.idleWatchers.count == 1)
        #expect(runtime.idleTasks.count == 1)
        #expect(runtime.pushStates["a-imap"] == .idling)
        // Idling is the healthy case, so there is nothing for the surface to show.
        #expect(runtime.pushStatus(for: "a-imap") == nil)
        // The engine and the router are wired exactly as before.
        #expect(runtime.syncEngines["a-imap"] != nil)
        #expect(await IMAPIdleHarness.waitUntilIdling(server, clock))
        runtime.teardown()
    }

    /// Gmail and Apple Mail are unaffected: no watcher, no push state, and the
    /// engine attaches exactly as it always did.
    @Test("a non-IMAP account gets no watcher and no push state")
    func aNonIMAPAccountGetsNoWatcher() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        runtime.attach(provider: FakeMailProvider(accountID: "a-gmail"), accountID: "a-gmail")

        #expect(runtime.idleWatchers.isEmpty)
        #expect(runtime.idleTasks.isEmpty)
        #expect(runtime.pushStates["a-gmail"] == nil)
        #expect(runtime.pushStatus(for: "a-gmail") == nil)
        // Absence of a watcher is not absence of syncing.
        #expect(runtime.syncEngines["a-gmail"] != nil)
        // No clock was ever consulted, so nothing IDLE-shaped started at all.
        #expect(await clock.requested.isEmpty)
        runtime.teardown()
    }

    /// `attach` runs more than once for the same account in one runtime —
    /// `attachStoredAccounts()` is called from `init` and again from
    /// `saveGmailCredentials`, and `connectAccount` calls `attach` directly. A
    /// second watcher must not appear.
    ///
    /// `connectionCount == 1` is the assertion that matters: two watchers would each
    /// take a lease, so the duplicate is visible as a second authenticated socket
    /// rather than only as a second dictionary entry.
    @Test("re-attaching the same account does not start a second watcher")
    func reAttachingDoesNotDuplicateTheWatcher() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = idlingServer()
        let provider = IMAPIdleHarness.provider(server)
        try runtime.store.saveAccount(imapAccount("a-imap"))

        runtime.attach(provider: provider, accountID: "a-imap")
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        let firstWatcher = runtime.idleWatchers["a-imap"]

        runtime.attach(provider: provider, accountID: "a-imap")
        runtime.attachStoredAccounts()

        #expect(runtime.idleWatchers.count == 1)
        #expect(runtime.idleTasks.count == 1)
        #expect(runtime.idleWatchers["a-imap"] === firstWatcher)
        // The decisive one: still ONE lease, so no second IDLE connection exists.
        #expect(await server.connectionCount == 1)
        #expect(await server.acquired == 1)
        runtime.teardown()
    }

    // MARK: - Both triggers, and the timer alone

    /// An untagged arrival during IDLE reaches the SAME per-account delta pass the
    /// poll timer reaches.
    ///
    /// Proven by effect rather than by inspecting a closure: the pass takes a second
    /// lease, the scripted server has none left, and `noScriptLeft` lands in
    /// `syncErrors` for that account. `syncErrors` starting nil is what makes the
    /// transition meaningful — a runtime that never called `syncNow` leaves it nil.
    @Test("an IDLE arrival triggers the account's delta pass")
    func anIdleArrivalTriggersADeltaPass() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = idlingServer()
        try runtime.store.saveAccount(imapAccount("a-imap"))
        runtime.attach(provider: IMAPIdleHarness.provider(server), accountID: "a-imap")
        // A second, unrelated account, so "this account's pass" is falsifiable: an
        // arrival on one mailbox must not force a delta pass on every other one.
        let other = FakeMailProvider(accountID: "a-other")
        other.failures["fetchThreads"] = [MailError.providerFailed(status: 500, message: "x")]
        runtime.attach(provider: other, accountID: "a-other")
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        #expect(runtime.lastSyncError(for: "a-imap") == nil)
        #expect(runtime.lastSyncError(for: "a-other") == nil)

        guard let connection = await server.connection(0) else { return }
        await connection.transport.enqueue(
            try IMAPDeltaHarness.fixtureText("imap-idle-one-arrival"))
        let watcher = try #require(runtime.idleWatchers["a-imap"])
        guard await IMAPIdleHarness.waitUntil("the notification", {
            await watcher.notificationCount == 1
        }) else { return }
        // Nothing yet: the arrival is still inside the coalesce window.
        #expect(runtime.lastSyncError(for: "a-imap") == nil)

        #expect(await clock.release(.seconds(1)))
        guard await IMAPIdleHarness.waitUntilOnMain("the IDLE-driven delta pass", {
            runtime.lastSyncError(for: "a-imap") != nil
        }) else { return }
        #expect(runtime.lastSyncError(for: "a-imap")?.contains("noScriptLeft") == true)
        // The pass asked for a lease of ITS OWN rather than reusing the idling
        // one: the watcher still holds the only granted lease, and the second
        // request is the one the script refused.
        #expect(await server.acquired == 1)
        #expect(await server.acquireFailures == 1)
        // Scoped to the account that saw the arrival: the other account was not
        // swept along, so `onNotification` is `syncNow(accountID:)` and not a
        // whole-app tick.
        #expect(runtime.lastSyncError(for: "a-other") == nil)
        runtime.teardown()
    }

    /// The poll timer's own entry point reaches the same pass, with the same marker,
    /// for the same account. Without this the test above could hold for a runtime in
    /// which IDLE had REPLACED the timer rather than joined it.
    @Test("the poll tick triggers the same delta pass for an IMAP account")
    func thePollTickTriggersTheSameDeltaPass() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = idlingServer()
        try runtime.store.saveAccount(imapAccount("a-imap"))
        runtime.attach(provider: IMAPIdleHarness.provider(server), accountID: "a-imap")
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        #expect(runtime.lastSyncError(for: "a-imap") == nil)

        // `syncOnce` is exactly what `startSyncTimer`'s loop calls.
        await runtime.syncOnce()

        #expect(runtime.lastSyncError(for: "a-imap")?.contains("noScriptLeft") == true)
        // The IDLE connection was not disturbed to make room for the poll — it is
        // still the watcher's own, still idling, and still has no `DONE` on it.
        #expect(runtime.idleWatchers["a-imap"] != nil)
        #expect(await IMAPIdleHarness.wire(server, 0).contains("DONE") == false)
        runtime.teardown()
    }

    /// A server that never advertises `IDLE`: the watcher ends terminally, the
    /// reason is surfaced, and the account still syncs on the timer alone.
    ///
    /// This is the "nothing regresses" criterion at the runtime level. The
    /// `pushStatus` assertion is what stops a silently absent feature — the failure
    /// mode this whole task keeps running into.
    @Test("an account without IDLE still syncs on the timer, and says why")
    func anAccountWithoutIdleStillSyncsOnTheTimer() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(capabilities: "IMAP4rev1",
                                   selectFixture: nil, doneCycles: 0),
        ])
        try runtime.store.saveAccount(imapAccount("a-imap"))
        runtime.attach(provider: IMAPIdleHarness.provider(server), accountID: "a-imap")

        guard await IMAPIdleHarness.waitUntilOnMain("the terminal outcome", {
            runtime.pushStates["a-imap"] == .notAdvertised
        }) else { return }
        #expect(runtime.pushStatus(for: "a-imap")?.contains("does not support IMAP IDLE") == true)
        // Terminal means terminal: no reconnect schedule was ever entered.
        #expect(await clock.requested.isEmpty)
        // The lease came back even though the run failed.
        #expect(await server.isBalanced)

        // And the timer still syncs it.
        #expect(runtime.lastSyncError(for: "a-imap") == nil)
        await runtime.syncOnce()
        #expect(runtime.lastSyncError(for: "a-imap")?.contains("noScriptLeft") == true)
        runtime.teardown()
    }

    @Test("an account with no selectable mailbox surfaces that reason")
    func noSelectableMailboxIsSurfaced() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = IMAPIdleHarness.Server(
            scripts: [IMAPIdleHarness.Script(selectFixture: nil, doneCycles: 0)],
            directory: try IMAPIdleHarness.noSelectableDirectory())
        try runtime.store.saveAccount(imapAccount("a-imap"))
        runtime.attach(provider: IMAPIdleHarness.provider(server), accountID: "a-imap")

        guard await IMAPIdleHarness.waitUntilOnMain("the terminal outcome", {
            runtime.pushStates["a-imap"] == .noSelectableMailbox
        }) else { return }
        #expect(runtime.pushStatus(for: "a-imap")?.contains("two-minute check") == true)
        #expect(await server.isBalanced)
        runtime.teardown()
    }

    // MARK: - Sign-out and teardown give the socket back

    /// Signing out stops the watcher, forgets its status, and — the part that is not
    /// merely bookkeeping — waits for the lease to actually come back.
    ///
    /// An unstopped watcher would hold an authenticated socket and a lease for an
    /// account whose mail, credential and row have just been deleted, and its next
    /// notification would call `syncNow` for an account with no provider.
    @Test("signing out stops the account's IDLE watcher and releases its lease")
    func signingOutStopsTheWatcher() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = idlingServer()
        try runtime.store.saveAccount(imapAccount("a-imap"))
        runtime.attach(provider: IMAPIdleHarness.provider(server), accountID: "a-imap")
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }
        guard let connection = await server.connection(0) else { return }

        // An arrival still inside its coalesce window when the sign-out lands. It
        // must not become a delta pass for a purged account.
        await connection.transport.enqueue(
            try IMAPDeltaHarness.fixtureText("imap-idle-one-arrival"))
        let watcher = try #require(runtime.idleWatchers["a-imap"])
        guard await IMAPIdleHarness.waitUntil("the pending notification", {
            await watcher.notificationCount == 1
        }) else { return }

        runtime.signOut("a-imap")

        #expect(runtime.idleWatchers["a-imap"] == nil)
        #expect(runtime.idleTasks["a-imap"] == nil)
        #expect(runtime.pushStates["a-imap"] == nil)
        #expect(runtime.syncEngines["a-imap"] == nil)
        #expect(runtime.store.accounts().contains { $0.id == "a-imap" } == false)
        // The socket really came back: `stop()` sent its DONE and `withSession`
        // released the lease.
        #expect(await IMAPIdleHarness.waitUntil("the lease to come back", {
            await server.isBalanced
        }))
        #expect(await IMAPIdleHarness.wire(server, 0).hasSuffix("DONE\r\n"))
        #expect(await connection.session.inFlightCount == 0)

        // `stop()` cancelled the open coalesce window, so no orphan timer is left
        // waiting on the clock for an account that no longer exists.
        //
        // Asserted on the CLOCK rather than on `runtime.lastSyncError`, and the
        // difference matters: `signOut` has already cleared `syncEngines`, so
        // `syncAccount`'s `guard let engine` returns early and a stray flush is
        // unobservable through runtime state — an assertion there passes whether or
        // not the cancel exists. The parked sleep is a property of the thing under
        // test, so it can actually fail.
        //
        // Note what the cancel does and does not do: the debounce body swallows the
        // cancellation (`try? await clock.sleep`) and still calls `flush`, so a pass
        // that was already owed is not dropped — it is brought forward. What the
        // cancel removes is the WAIT, which is why the window is gone from the clock
        // rather than merely unreferenced. `waitUntil(server.isBalanced)` above is
        // what orders this: the release it waits for happens after `watcher.stop()`
        // inside the same task, so the cancel has provably already run and nothing
        // here needs a second wait.
        #expect(await clock.pending.contains(.seconds(1)) == false)
        #expect(await clock.release(.seconds(1)) == false)
        // And no NEW window was opened on the way out.
        #expect(await clock.requestCount(of: .seconds(1)) == 1)
        #expect(runtime.lastSyncError(for: "a-imap") == nil)
        #expect(await server.acquired == 1)
    }

    /// A terminal outcome that lands AFTER the watcher was stopped must not write a
    /// status back for an account that no longer exists.
    ///
    /// The window is real: the run task decides `.notAdvertised` only after its
    /// `acquire` and capability check have completed, and a sign-out can land in the
    /// middle of that. The gate holds the run inside `acquire` so the race is a
    /// state the test controls rather than a timing accident — a flaky version of
    /// this test would be worse than none.
    ///
    /// `stopIdleWatcher` rather than `signOut` only because it returns the task, so
    /// "the run has fully finished, including recording its outcome" is an awaitable
    /// point instead of a settle loop. It is the same call `signOut` makes — which
    /// `signingOutStopsTheWatcher` pins independently.
    @Test("a terminal outcome arriving after the watcher was stopped is not recorded")
    func aTerminalOutcomeAfterStoppingIsNotRecorded() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let server = IMAPIdleHarness.Server(
            scripts: [IMAPIdleHarness.Script(capabilities: "IMAP4rev1",
                                             selectFixture: nil, doneCycles: 0)],
            gateAcquire: true)
        try runtime.store.saveAccount(imapAccount("a-imap"))
        runtime.attach(provider: IMAPIdleHarness.provider(server), accountID: "a-imap")

        // Parked inside `acquire`: started, outcome undecided.
        guard await IMAPIdleHarness.waitUntil("the acquire attempt", {
            await server.acquireAttempts == 1
        }) else { return }
        #expect(runtime.pushStates["a-imap"] == .idling)

        let stopping = try #require(runtime.stopIdleWatcher(accountID: "a-imap"))
        #expect(runtime.pushStates["a-imap"] == nil)

        // Now let the run reach its terminal `.notAdvertised`.
        await server.openAcquireGate()
        await stopping.value

        #expect(runtime.pushStates["a-imap"] == nil)
        #expect(runtime.pushStates.isEmpty)
        #expect(runtime.idleWatchers.isEmpty)
        #expect(await server.isBalanced)
    }

    /// `teardown()` stops EVERY watcher, not the first one. Two accounts, because a
    /// loop that broke after one would pass with a single account.
    @Test("teardown stops every IDLE watcher")
    func teardownStopsEveryWatcher() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let runtime = self.runtime(clock)
        let first = idlingServer()
        let second = idlingServer()
        try runtime.store.saveAccount(imapAccount("a-one"))
        try runtime.store.saveAccount(imapAccount("a-two"))
        runtime.attach(provider: IMAPIdleHarness.provider(first), accountID: "a-one")
        runtime.attach(provider: IMAPIdleHarness.provider(second), accountID: "a-two")
        guard await IMAPIdleHarness.waitUntilIdling(first, clock) else { return }
        guard await IMAPIdleHarness.waitUntilIdling(second, clock) else { return }
        #expect(runtime.idleWatchers.count == 2)

        runtime.teardown()

        #expect(runtime.idleWatchers.isEmpty)
        #expect(runtime.idleTasks.isEmpty)
        #expect(runtime.pushStates.isEmpty)
        #expect(await IMAPIdleHarness.waitUntil("both leases to come back", {
            let firstBalanced = await first.isBalanced
            let secondBalanced = await second.isBalanced
            return firstBalanced && secondBalanced
        }))
        #expect(await IMAPIdleHarness.wire(first, 0).hasSuffix("DONE\r\n"))
        #expect(await IMAPIdleHarness.wire(second, 0).hasSuffix("DONE\r\n"))
    }
}
