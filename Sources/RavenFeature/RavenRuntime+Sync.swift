import Foundation
import AinkradAppKit

/// Sync orchestration: the one poll loop, the per-account delta syncs, the
/// detached backfills, and the engine/provider attachment that wires them up.
///
/// An extension on `RavenRuntime`, not a separate collaborator, deliberately.
/// Every method here reads or writes the SAME per-account state
/// (`syncStates`/`syncErrors`/`truncatedBackfills`/`syncEngines`) that
/// `signOut` and the settings surfaces read, and moving that state into its own
/// object would mean either exposing it through a dozen forwarding accessors or
/// having two places that know what "this account is backfilling" means. The
/// state stays declared in `RavenRuntime.swift`, in one place, and the three
/// published dictionaries keep their `private(set)` — this file mutates them
/// only through the named mutators next to their declarations
/// (`setSyncState`, `setSyncError`, `setTruncated`), which is narrower than the
/// `internal(set)` a cross-file extension would otherwise have forced.
extension RavenRuntime {

    // MARK: The poll loop

    /// Polls on a timer and on window focus (`syncNow`, called by the UI). No
    /// Pub/Sub push in M0 — that needs a public HTTPS endpoint, which is
    /// disproportionate for a personal client.
    func startSyncTimer() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    /// The timer's tick. `syncDelta()` deliberately does NOT throw on a
    /// transient per-thread failure — it holds the cursor and records the
    /// failure on the account/`state` instead, precisely so a flaky network
    /// blip can't advance the cursor past mail that was never durably synced
    /// (see `SyncEngine.syncDelta`'s own documentation). A bare `do/catch`
    /// around the call would miss that failure entirely and log nothing, so
    /// this reads `syncEngine.state` after the call whether or not it threw,
    /// exactly like `syncNow()`. `outbox.drain()` never throws either — it
    /// records failures on the entries themselves — so `refreshOutboxSnapshots()`
    /// is what actually surfaces those, into `outboxDeadLettered`/`outboxNeedsReview`.
    /// Nothing here logs message content, addresses, or tokens: only the
    /// `String(describing:)` of a `MailError`/status, matching `syncNow`.
    /// Services EVERY connected account on this one tick — one timer for the
    /// app, never one per account. Each account is synced in its own
    /// `syncAccount` call, whose failure is recorded against that account and
    /// then left behind: the loop continues, so a broken or rate-limited
    /// account cannot stall the accounts after it in the pass. Accounts are
    /// visited in id order so the pass is deterministic rather than
    /// dictionary-ordered.
    ///
    /// `outbox.drain()` never throws either — it records failures on the
    /// entries themselves — so `refreshOutboxSnapshots()` is what actually
    /// surfaces those. One drain covers every account, since the outbox routes
    /// each entry to its own provider.
    func syncOnce() async {
        for accountID in syncEngines.keys.sorted() {
            await syncAccount(accountID)
        }
        await outbox.drain()
        refreshOutboxSnapshots()
        model.reload()
    }

    // MARK: Delta sync

    /// Delta-syncs one account, or every account when none is named. Each
    /// account is handled independently — see `syncAccount`.
    public func syncNow(accountID: String? = nil) async {
        let targets = accountID.map { [$0] } ?? syncEngines.keys.sorted()
        for target in targets { await syncAccount(target) }
        model.reload()
    }

    /// One account's delta sync, with its outcome recorded against THAT
    /// account. `syncDelta()` deliberately does NOT throw on a transient
    /// per-thread failure — it holds the cursor and records the failure on the
    /// account/`state` instead, precisely so a flaky network blip can't advance
    /// the cursor past mail that was never durably synced (see
    /// `SyncEngine.syncDelta`'s own documentation). A bare `do/catch` around
    /// the call would miss that failure entirely, so this reads
    /// `engine.state` after the call whether or not it threw.
    private func syncAccount(_ accountID: String) async {
        guard let engine = syncEngines[accountID] else { return }
        do {
            try await engine.syncDelta()
            setSyncError(nil, for: accountID)
        } catch {
            setSyncError(String(describing: error), for: accountID)
        }
        setSyncState(engine.state, for: accountID)
        if case .failed(let message) = engine.state {
            setSyncError(message, for: accountID)
        }
        refreshAggregateSyncError()
    }

    // MARK: Backfill and resync

    /// Kicks off `runBackfill()` in a new detached-from-the-caller `Task`
    /// (still `@MainActor`-isolated, same as `startSyncTimer`'s poll loop) so
    /// whoever calls this (`connectAccount`, `resyncFromScratch`) does not
    /// block on it. Cancels any backfill already in flight first — starting
    /// a second one for the same runtime while the first is still walking
    /// pages would race writes into the same store. `isBackfilling` is set
    /// here, synchronously, BEFORE the `Task` below is even scheduled to
    /// run — not inside `runBackfill()` — so there is no window between a
    /// caller checking it and this method flipping it in which a second
    /// caller on the same main actor could slip through.
    func startBackfill(accountID: String) {
        backfillTasks[accountID]?.cancel()
        backfillingAccounts.insert(accountID)
        backfillTasks[accountID] = Task { [weak self] in
            await self?.runBackfill(accountID: accountID)
        }
    }

    /// Re-walks the full sync window from scratch, kicking the walk off and
    /// returning immediately — exactly the shape `connectAccount` uses for
    /// its own backfill (see `startBackfill`), and for the same reason:
    /// awaiting `runBackfill()` here froze the "Resync from scratch" button
    /// for the length of a full 90-day walk, the same defect already fixed
    /// for Connect. `SyncEngine.backfill()` always does a fresh page walk
    /// (not a delta against the stored cursor), so kicking it off again IS
    /// the "resync from scratch" the Accounts surface offers — no separate
    /// code path needed.
    ///
    /// REFUSES a second call while one is already running, rather than
    /// cancelling the first and coalescing into the new one — see
    /// `isBackfilling`'s documentation for why cancellation of the wrapper
    /// `Task` alone is not good enough here. A caller that wants to know
    /// whether the request was actually honored can check `isResyncing`
    /// immediately after calling this.
    /// Resyncs one account, or — with no argument — every attached account.
    /// The per-account refusal is unchanged: a second call for an account
    /// already walking pages is ignored, while a different account may start
    /// its own walk, since the two write to different shards.
    public func resyncFromScratch(accountID: String? = nil) {
        // Keyed off the engines rather than the attached providers: a backfill
        // is an engine's walk, and an account without an engine has nothing to
        // resync.
        let targets = accountID.map { [$0] } ?? syncEngines.keys.sorted()
        for target in targets {
            guard !backfillingAccounts.contains(target) else {
                host.log.info("Raven: resync already in progress for \(target); " +
                              "ignoring the new request.")
                continue
            }
            startBackfill(accountID: target)
        }
    }

    /// Whether a backfill (from `connectAccount` or `resyncFromScratch`) is
    /// currently walking pages for `accountID`. Exposed read-only so a caller
    /// — tests in particular — can confirm a `resyncFromScratch` call was
    /// refused rather than silently starting a second walk.
    public func isResyncing(_ accountID: String) -> Bool {
        backfillingAccounts.contains(accountID)
    }

    /// Whether ANY account is currently backfilling.
    public var isResyncing: Bool { !backfillingAccounts.isEmpty }

    /// Runs a full backfill. Progress reaches the Accounts surface via
    /// `SyncEngine.onChange` (wired in `attach()`), which pushes every
    /// `state`/`lastBackfillTruncated` change straight into `mirrorSyncEngineState()`
    /// as it happens — see that property's documentation. This used to poll
    /// `syncEngine.state` off a 500ms timer instead; the timer is gone, not
    /// just idle, so there is no periodic task left running for as long as a
    /// backfill happens to take.
    ///
    /// A failure here is NOT swallowed: `SyncEngine.backfill()` already
    /// records it onto the account's `state`/`lastError` before rethrowing
    /// (see that method), and the `catch` below additionally surfaces it via
    /// `lastSyncError`, matching `syncNow()`/`syncOnce()`'s existing
    /// convention — so a failure in this detached call still reaches the UI
    /// exactly as it did when `connectAccount` awaited it inline.
    ///
    /// `isBackfilling` is reset here, unconditionally, whether the walk
    /// succeeded, failed, or was cancelled — this is the one place a
    /// `resyncFromScratch()` guarded on it is guaranteed to unblock.
    private func runBackfill(accountID: String) async {
        defer { backfillingAccounts.remove(accountID) }
        guard let engine = syncEngines[accountID] else { return }
        do {
            try await engine.backfill()
            setSyncError(nil, for: accountID)
        } catch {
            setSyncError(String(describing: error), for: accountID)
        }
        refreshAggregateSyncError()
        setSyncState(engine.state, for: accountID)
        setTruncated(engine.lastBackfillTruncated, for: accountID)
        model.reload()
    }

    // MARK: Engine attachment

    /// Mirrors `syncEngine.state`/`lastBackfillTruncated` into this
    /// `@Observable` instance's own properties and reloads `model`. Wired as
    /// `SyncEngine.onChange` by `attach()` so every page of a backfill (and
    /// every `syncDelta()` state transition) pushes here instead of the
    /// Accounts surface having to poll for it.
    private func mirrorSyncEngineState(accountID: String) {
        guard let engine = syncEngines[accountID] else { return }
        setSyncState(engine.state, for: accountID)
        setTruncated(engine.lastBackfillTruncated, for: accountID)
        model.reload()
    }

    /// Test-only seam: attaches an arbitrary `MailProvider` to the router
    /// WITHOUT building a `SyncEngine` for it — the difference from
    /// `attach(provider:accountID:)` below, which is why it survived that
    /// method losing its `GmailProvider`-specific signature.
    /// `RavenAgentBridgeTests` already swaps `syncEngine` directly for the same
    /// reason (exercising a real `RavenRuntime` without a live network); this
    /// lets `searchArchive` be exercised the same way, without widening the
    /// public surface.
    func attachTestProvider(_ provider: MailProvider, accountID: String) {
        providers.attach(provider, accountID: accountID)
    }

    /// Attaches any `MailProvider` — no longer only Gmail's. `SyncEngine`
    /// itself is provider-agnostic (it only calls `MailProvider`), so a
    /// read-only backend attaches and backfills through exactly this path; its
    /// mutations are refused later, at `MailProviderRouter.writableProvider`.
    func attach(provider: MailProvider, accountID: String) {
        providers.attach(provider, accountID: accountID)
        let engine = SyncEngine(store: store, provider: provider, accountID: accountID)
        engine.onChange = { [weak self] in self?.mirrorSyncEngineState(accountID: accountID) }
        engine.onNewThreads = { [weak self] threadIDs in self?.applyRules(threadIDs: threadIDs) }
        syncEngines[accountID] = engine
    }

    /// Attaches a provider for EVERY account already in the store — one per
    /// account, whatever its kind, so a relaunch restores every connected
    /// mailbox rather than the arbitrary first one.
    ///
    /// Each account is built independently through `ProviderFactory`, and a
    /// failure is logged and SKIPPED rather than thrown: one account naming a
    /// kind this build cannot construct (a row written by a newer build, an
    /// Apple Mail folder that no longer resolves) must not stop the accounts
    /// after it from attaching. Nothing here logs an address or a token — only
    /// the account id and the `String(describing:)` of the error, matching
    /// `signOut`'s convention.
    func attachStoredAccounts() {
        for account in store.accounts() {
            do {
                attach(provider: try providerFactory.makeProvider(for: account),
                       accountID: account.id)
            } catch {
                host.log.error("Raven: account \(account.id) could not be attached: " +
                               "\(String(describing: error))")
            }
        }
    }
}
