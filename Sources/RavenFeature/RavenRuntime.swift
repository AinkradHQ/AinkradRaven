import Foundation
import AinkradAppKit

/// Result of a deliberate "search all mail" act — see `RavenRuntime.
/// searchArchive`. Distinct `.results([])` vs `.failed` on purpose: a remote
/// search that genuinely found nothing must never look the same as one that
/// couldn't run at all (rate-limited, unauthenticated, transport failure).
public enum ArchiveSearchState: Equatable {
    case idle
    case searching
    case results([ThreadSummary])
    case failed(String)
}

/// One instance per `HostServices`, so the on-screen UI and the MCP server
/// (`RavenApp.makeMCPServer`) drive the SAME store, outbox, and account state
/// rather than two detached copies — `RavenApp` caches one runtime per host
/// and hands it to both.
///
/// Several accounts can be connected at once: one `SyncEngine` and one
/// attached `MailProvider` per account, keyed by account id, all serviced by
/// the SAME single 120-second poll loop — one timer for the app, not one per
/// account (see `syncOnce`). Per-account sync state is tracked separately so a
/// failure on one account is independently observable and cannot stall the
/// others.
@MainActor @Observable public final class RavenRuntime {
    public let store: DocumentMailStore
    public let outbox: Outbox
    public let model: RavenViewModel

    /// Which provider belongs to which account. The outbox routes each entry
    /// through this, and `RavenMCPOperations`' `include_archive` path fans out
    /// over it — replacing M0's single forwarding proxy, which could only ever
    /// answer for one account. Empty until an account is authorized; an
    /// operation that needs a provider then simply finds none, handled by the
    /// same failure paths as before rather than a special case.
    public let providers: MailProviderRouter

    private let host: HostServices
    private var auth: GmailAuth?
    /// One engine per connected account. Not `private` — see `syncEngine`
    /// below for the test seam that writes here.
    var syncEngines: [String: SyncEngine] = [:]
    /// Test-only seam preserved from M0, where there was exactly one engine:
    /// reading gives the sole engine (`nil` if there are none or several),
    /// writing files the engine under its own `accountID`. `RavenAgentBridgeTests`
    /// uses this to swap in an engine built around a scriptable
    /// `FakeMailProvider`; production code always goes through `syncEngines`.
    var syncEngine: SyncEngine? {
        get { syncEngines.count == 1 ? syncEngines.values.first : nil }
        set {
            guard let newValue else { syncEngines = [:]; return }
            syncEngines[newValue.accountID] = newValue
        }
    }
    /// The running poll loop started in `init` and cancelled in `teardown()`.
    /// Not resumed once cancelled — a closed instance must stop calling
    /// Gmail, not just stop being observed. ONE loop for every account.
    private var syncTask: Task<Void, Never>?
    /// The detached 90-day backfills kicked off by `connectAccount`/
    /// `resyncFromScratch`, one per account. Cancelled (never resumed) in
    /// `teardown()`, exactly like `syncTask` — a closed instance must stop
    /// calling Gmail — and also cancelled for the one account that is signed
    /// out, so a backfill for an account that no longer exists locally cannot
    /// keep writing to the store underneath it while other accounts' backfills
    /// continue untouched.
    private var backfillTasks: [String: Task<Void, Never>] = [:]
    /// The accounts with a backfill currently walking pages. An id is inserted
    /// synchronously inside `startBackfill(accountID:)` — before the `Task` it
    /// creates has had any chance to run — and removed at the end of
    /// `runBackfill`, on sign-out, and on teardown. See
    /// `resyncFromScratch`'s documentation for why a second call for the SAME
    /// account is refused rather than cancelling-and-restarting:
    /// `SyncEngine.backfill()` never checks `Task.isCancelled`, so cancelling
    /// the wrapper `Task` alone cannot be trusted to stop a real network walk
    /// already in flight, and two overlapping walks writing into the same
    /// account's shards is exactly what must never happen. Different accounts
    /// write to different shards, so they may backfill concurrently.
    private var backfillingAccounts: Set<String> = []
    private var contextToken: PluginContextToken?
    private var actionTokens: [AgentActionToken] = []

    /// Not a credential — the OAuth client id is only ever a lookup key
    /// against Google, and the user needs to see what they typed to fix a
    /// typo. Persisted as a document, unlike the secret below.
    private static let clientIDKey = "gmail-client-id"
    /// The client secret IS a credential (see `GmailAuth`'s own documentation
    /// of the same point). It is read from and written to `host.secrets`
    /// ONLY — never `host.documents`, never logged, never echoed back into
    /// any field.
    private static let clientSecretKey = "gmail-client-secret"

    /// Per-account sync state. Independently observable, so one account's
    /// failure is visible as that account's failure rather than as a single
    /// app-wide status that whichever account synced last happens to own.
    public private(set) var syncStates: [String: SyncState] = [:]
    /// Per-account most recent sync/backfill failure.
    public private(set) var syncErrors: [String: String] = [:]
    /// The accounts whose most recent backfill stopped early.
    public private(set) var truncatedBackfills: Set<String> = []

    public func syncState(for accountID: String) -> SyncState {
        syncStates[accountID] ?? .idle
    }
    public func lastSyncError(for accountID: String) -> String? {
        syncErrors[accountID]
    }
    public func lastBackfillTruncated(for accountID: String) -> Bool {
        truncatedBackfills.contains(accountID)
    }

    /// App-wide roll-up of `syncStates`, for the places that legitimately show
    /// one status for everything (the Settings panel's change trigger). A
    /// failure anywhere wins, because "some account is broken" must not be
    /// hidden by another account being idle; otherwise an in-progress backfill
    /// wins, with the thread counts summed.
    public var syncState: SyncState {
        if let failure = syncStates.values.compactMap({ state -> String? in
            if case .failed(let message) = state { return message }
            return nil
        }).sorted().first {
            return .failed(failure)
        }
        let backfilling = syncStates.values.compactMap { state -> Int? in
            if case .backfilling(let count) = state { return count }
            return nil
        }
        if !backfilling.isEmpty { return .backfilling(threadsSynced: backfilling.reduce(0, +)) }
        if syncStates.values.contains(.delta) { return .delta }
        return .idle
    }

    /// Surfaced separately from `syncState` on purpose — see `SyncEngine`'s
    /// own documentation of `lastBackfillTruncated`: it is a plain flag, not
    /// a `SyncState` case, so a view that renders only `syncState` would
    /// silently miss it. True when it happened on ANY account; per-account
    /// truth is `lastBackfillTruncated(for:)`.
    public var lastBackfillTruncated: Bool { !truncatedBackfills.isEmpty }
    /// The most recently recorded failure across all accounts, kept for the
    /// surfaces (and the Inbox empty state) that show one line. Per-account
    /// truth is `lastSyncError(for:)`.
    public private(set) var lastSyncError: String? {
        // Mirrored into `model` (rather than the view reading `runtime`
        // directly) so `InboxSurface` can tell "sync failed" apart from
        // "nothing synced yet" from `model` alone, matching how it already
        // gets everything else (summaries, selection) through the view model.
        didSet { model.lastSyncError = lastSyncError }
    }
    /// Result of the most recent `searchArchive` call. `InboxSurface` renders
    /// this as a distinct "results from all mail" list alongside (not
    /// replacing) the windowed Inbox list — see `searchArchive`'s
    /// documentation for why a separate presentation is the honest one.
    public private(set) var archiveSearchState: ArchiveSearchState = .idle
    public private(set) var outboxDeadLettered: [OutboxEntry] = []
    /// Entries whose outcome is unknown because a previous process died
    /// mid-send — see `Outbox.needsReview()`. Never auto-resolved.
    public private(set) var outboxNeedsReview: [OutboxEntry] = []

    public init(host: HostServices) {
        self.host = host
        let store = DocumentMailStore(documents: host.documents)
        self.store = store

        let providers = MailProviderRouter()
        self.providers = providers
        // The outbox is built exactly once, here, and routes per entry through
        // `providers` — so it works before any account is connected and needs
        // no rebuilding when one is (or several are).
        let outbox = Outbox(documents: host.documents, router: providers)
        self.outbox = outbox
        self.model = RavenViewModel(store: store, outbox: outbox)
        // The one-shot wake `Outbox` schedules for the earliest held/
        // scheduled entry calls back into `drainOutbox()` (not `outbox.
        // drain()` directly) so a wake also refreshes the dead-letter/
        // needs-review snapshots the Accounts surface renders — see
        // `Outbox.onWake`'s own documentation.
        outbox.onWake = { [weak self] in await self?.drainOutbox() }

        // Baked credentials (see `BakedOAuthCredentials` / `isCredentialsBaked`)
        // are preferred over anything the user typed in manually — that is
        // the whole point of baking them in: the Accounts surface should
        // need to show only a Connect button. `BakedOAuthCredentials.
        // clientSecret` is read directly into `GmailAuth`'s init argument and
        // never written to `host.secrets` or `host.documents` — that keeps
        // the number of at-rest copies of the secret to the one already
        // compiled into the binary, rather than adding a Keychain copy of a
        // value the binary already carries. (The refresh TOKEN `GmailAuth`
        // obtains once the user signs in is still persisted to
        // `host.secrets` exactly as before — that is a real per-account
        // credential, not a static baked-in client secret, and there is only
        // one of it regardless.)
        if let clientID = BakedOAuthCredentials.clientID, let clientSecret = BakedOAuthCredentials.clientSecret {
            let auth = GmailAuth(secrets: host.secrets, clientID: clientID, clientSecret: clientSecret)
            self.auth = auth
            attachStoredAccounts(auth: auth)
        } else if let idData = host.documents.data(forKey: Self.clientIDKey),
           let clientID = String(data: idData, encoding: .utf8),
           let clientSecret = host.secrets.secret(forKey: Self.clientSecretKey) {
            // Fallback for a developer build with no Config/oauth-client.json:
            // the manually-entered credentials saved via `saveCredentials`.
            let auth = GmailAuth(secrets: host.secrets, clientID: clientID, clientSecret: clientSecret)
            self.auth = auth
            attachStoredAccounts(auth: auth)
        }
        model.reload()
        refreshOutboxSnapshots()
        if let corrupt = store.lastCorruptDocumentKey {
            // Never silent: a document that exists but cannot be decoded is
            // surfaced, and the store refuses to overwrite it (see
            // `DocumentMailStore.loadStrict`).
            host.log.error("Raven: document '\(corrupt)' is present but could not be decoded; " +
                           "it will not be overwritten.")
        }

        let registration = RavenAgentBridge.register(host: host, model: model)
        contextToken = registration.context
        actionTokens = registration.actions
        startSyncTimer()
    }

    /// Releases everything this instance registered with `host` and stops the
    /// poll loop. Called from `RavenApp.teardown` — see that file's own
    /// documentation of why a per-instance runtime that never tears down is a
    /// leak, not a cache. Safe to call more than once (each step is a no-op
    /// the second time).
    /// Attaches a provider for EVERY account already in the store — one per
    /// account, so a relaunch restores every connected mailbox rather than the
    /// arbitrary first one. Each account's refresh token is looked up by
    /// `GmailAuth` under that account's id, so one `auth` serves them all.
    private func attachStoredAccounts(auth: GmailAuth) {
        for account in store.accounts() {
            attach(provider: GmailProvider(accountID: account.id, auth: auth),
                   accountID: account.id)
        }
    }

    public func teardown() {
        syncTask?.cancel()
        syncTask = nil
        outbox.teardownWake()
        for task in backfillTasks.values { task.cancel() }
        backfillTasks = [:]
        backfillingAccounts = []
        if let contextToken {
            host.context.remove(contextToken)
            self.contextToken = nil
        }
        for token in actionTokens {
            host.actions.remove(token)
        }
        actionTokens = []
    }

    // MARK: Credentials

    /// The client id currently saved, if any — safe to show back in the field
    /// the user typed it into. There is deliberately no equivalent getter for
    /// the secret; see `clientSecretKey`.
    public var savedClientID: String? {
        BakedOAuthCredentials.clientID
            ?? host.documents.data(forKey: Self.clientIDKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    public var hasCredentials: Bool { auth != nil }

    /// Whether `BakedOAuthCredentials` supplied both values at build time
    /// (see `scripts/generate-oauth-credentials.sh`). When true, the
    /// Accounts surface shows only the Connect button and the connected
    /// account — no manual client id/secret fields, since there is nothing
    /// for the user to enter.
    public var isCredentialsBaked: Bool {
        BakedOAuthCredentials.clientID != nil && BakedOAuthCredentials.clientSecret != nil
    }

    public func saveCredentials(clientID: String, clientSecret: String) {
        guard let data = clientID.data(using: .utf8) else { return }
        host.documents.setData(data, forKey: Self.clientIDKey)
        host.secrets.setSecret(clientSecret, forKey: Self.clientSecretKey)
        let auth = GmailAuth(secrets: host.secrets, clientID: clientID, clientSecret: clientSecret)
        self.auth = auth
        attachStoredAccounts(auth: auth)
    }

    // MARK: Accounts

    public var accounts: [MailAccount] { store.accounts() }

    /// The account a freshly composed message (not a reply — a reply takes its
    /// thread's account) goes out from: the Inbox's account filter if the user
    /// has chosen one, otherwise the only connected account.
    ///
    /// Deliberately `nil` when several accounts are connected and none is
    /// chosen, rather than falling back to `accounts.first`. An unattributed
    /// message stays queued instead of being transmitted from an arbitrary
    /// mailbox, and Compose says so — the from-account picker that removes the
    /// ambiguity is the UI half of this milestone. Nothing changes while a
    /// single account is connected.
    public var composingAccountID: String? {
        if let chosen = model.accountID { return chosen }
        return providers.sole?.accountID
    }

    /// Runs the loopback OAuth flow, saves the resulting account, attaches
    /// its provider, and returns — WITHOUT waiting for the 90-day backfill
    /// that follows. The account is already saved as `.syncing` by the time
    /// this returns, so the Connect button's `Task` completes as soon as the
    /// browser sign-in itself finishes, not a minute later once every thread
    /// in the window has been fetched. The backfill itself runs as a
    /// separate, detached task (`startBackfill()`) that publishes progress
    /// into `syncState`/`model` as it goes — see that method's documentation.
    /// `onAuthorizationURL` lets the caller present the URL if the browser
    /// doesn't visibly pop (see `GmailAuth.authorize`).
    public func connectAccount(onAuthorizationURL: (@Sendable (URL) -> Void)? = nil) async throws {
        guard let auth else { throw MailError.notAuthenticated(accountID: "") }
        let (accountID, address) = try await auth.authorize(onAuthorizationURL: onAuthorizationURL)
        try store.saveAccount(MailAccount(id: accountID, provider: .gmail, address: address,
                                          displayName: address, state: .syncing))
        attach(provider: GmailProvider(accountID: accountID, auth: auth), accountID: accountID)
        // Deliberately does NOT scope the Inbox to the account just added:
        // connecting a second mailbox must not hide the first one. The unified
        // list (`model.accountID == nil`) covers every account; a per-account
        // filter is the user's choice, not a side effect of signing in.
        model.reload()
        startBackfill(accountID: accountID)
    }

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
    private func startBackfill(accountID: String) {
        backfillTasks[accountID]?.cancel()
        backfillingAccounts.insert(accountID)
        backfillTasks[accountID] = Task { [weak self] in
            await self?.runBackfill(accountID: accountID)
        }
    }

    /// Signing out must leave nothing of the account behind. Three things go,
    /// in this order:
    ///
    /// 1. the refresh token (`auth.signOut`);
    /// 2. every queued outbox entry for the account — otherwise, because the
    ///    outbox transmits through whatever provider is attached *now*, a send
    ///    queued for this account would go out from the next account someone
    ///    connects. `OutboxEntry.accountID` blocks that even if this purge is
    ///    somehow missed; the purge is what stops it lingering at all;
    /// 3. every local document — threads, bodies, index shards, labels, and
    ///    the account row. Leaving the mail readable on disk after the user
    ///    has disconnected the account is not a cache.
    ///
    /// Every step is scoped to exactly ONE account: with several connected,
    /// signing out of A must leave B's mail, labels, bodies and queued sends
    /// completely intact. `store.purge` is already account-keyed (its month
    /// registry, body index and label document are all per-account), and
    /// `outbox.purge` only drops entries stamped with this account; what this
    /// method must not do — and no longer does — is tear down the shared
    /// provider/engine/backfill state, because that is now per account too.
    public func signOut(_ accountID: String) {
        auth?.signOut(accountID: accountID)
        outbox.purge(accountID: accountID)
        do {
            try store.purge(accountID: accountID)
        } catch {
            // A corrupt document can block the purge. Say so rather than
            // pretending the mail is gone.
            host.log.error("Raven: signing out \(accountID) could not fully purge local mail: " +
                           "\(error)")
        }
        refreshOutboxSnapshots()
        // A backfill in flight for THIS account must stop — it would otherwise
        // keep fetching and writing threads for an account this instance no
        // longer has a provider for. Other accounts' backfills keep running.
        backfillTasks[accountID]?.cancel()
        backfillTasks[accountID] = nil
        backfillingAccounts.remove(accountID)
        providers.detach(accountID: accountID)
        syncEngines[accountID] = nil
        syncStates[accountID] = nil
        syncErrors[accountID] = nil
        truncatedBackfills.remove(accountID)
        if outbox.accountID == accountID { outbox.accountID = nil }
        if model.accountID == accountID {
            // Back to the unified view rather than to `accounts.first` — a
            // filter on an account that no longer exists must fall back to
            // "everything", not to an arbitrary other mailbox.
            model.accountID = nil
        }
        model.reload()
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
            syncErrors[accountID] = nil
        } catch {
            syncErrors[accountID] = String(describing: error)
        }
        syncStates[accountID] = engine.state
        if case .failed(let message) = engine.state {
            syncErrors[accountID] = message
        }
        refreshAggregateSyncError()
    }

    /// Recomputes the one-line roll-up from the per-account errors. Ordered by
    /// account id so the line shown is deterministic rather than dependent on
    /// which account's sync finished last, and `nil` only when NO account is
    /// currently failing.
    private func refreshAggregateSyncError() {
        lastSyncError = syncErrors.keys.sorted().compactMap { syncErrors[$0] }.first
    }

    /// Polls on a timer and on window focus (`syncNow`, called by the UI). No
    /// Pub/Sub push in M0 — that needs a public HTTPS endpoint, which is
    /// disproportionate for a personal client.
    private func startSyncTimer() {
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
            syncErrors[accountID] = nil
        } catch {
            syncErrors[accountID] = String(describing: error)
        }
        refreshAggregateSyncError()
        syncStates[accountID] = engine.state
        setTruncated(engine.lastBackfillTruncated, for: accountID)
        model.reload()
    }

    private func setTruncated(_ truncated: Bool, for accountID: String) {
        if truncated { truncatedBackfills.insert(accountID) }
        else { truncatedBackfills.remove(accountID) }
    }

    /// Mirrors `syncEngine.state`/`lastBackfillTruncated` into this
    /// `@Observable` instance's own properties and reloads `model`. Wired as
    /// `SyncEngine.onChange` by `attach()` so every page of a backfill (and
    /// every `syncDelta()` state transition) pushes here instead of the
    /// Accounts surface having to poll for it.
    private func mirrorSyncEngineState(accountID: String) {
        guard let engine = syncEngines[accountID] else { return }
        syncStates[accountID] = engine.state
        setTruncated(engine.lastBackfillTruncated, for: accountID)
        model.reload()
    }

    /// Test-only seam: attaches an arbitrary `MailProvider` (e.g.
    /// `FakeMailProvider`) directly to the proxy, bypassing `attach(provider:
    /// accountID:)`'s `GmailProvider`-specific signature. `RavenAgentBridgeTests`
    /// already swaps `syncEngine` directly for the same reason (exercising a
    /// real `RavenRuntime` without a live network); this lets `searchArchive`
    /// be exercised the same way, without widening the public surface.
    func attachTestProvider(_ provider: MailProvider, accountID: String) {
        providers.attach(provider, accountID: accountID)
    }

    private func attach(provider: GmailProvider, accountID: String) {
        providers.attach(provider, accountID: accountID)
        let engine = SyncEngine(store: store, provider: provider, accountID: accountID)
        engine.onChange = { [weak self] in self?.mirrorSyncEngineState(accountID: accountID) }
        engine.onNewThreads = { [weak self] threadIDs in self?.applyRules(threadIDs: threadIDs) }
        syncEngines[accountID] = engine
    }

    // MARK: Rules

    /// The user's saved filter rules — read fresh from `host.documents` on
    /// every access rather than cached, since `RavenSettingsView`'s rule
    /// editor writes the same document and must be reflected on the very
    /// next delta sync without this runtime needing to be told to reload.
    public var rules: RuleSet {
        get { RuleSet.load(documents: host.documents) }
        set { newValue.save(documents: host.documents) }
    }

    /// Runs the saved rules against exactly the thread ids a delta sync just
    /// discovered — see `SyncEngine.onNewThreads`'s documentation for why
    /// this must never be called with a wider set (e.g. everything in the
    /// store). Goes through `RuleEngine.apply`, which itself only ever calls
    /// `ThreadMutationApplier`/`outbox.enqueue` — never a provider directly.
    private func applyRules(threadIDs: [String]) {
        let ruleSet = rules
        guard !ruleSet.rules.isEmpty else { return }
        RuleEngine.apply(ruleSet: ruleSet, threadIDs: threadIDs, store: store, outbox: outbox)
        model.reload()
    }

    /// Read-modify-write of the CURRENT account row.
    ///
    /// The Settings signature field used to write back a `MailAccount` value
    /// captured when the row was rendered, so every keystroke clobbered
    /// `syncCursor`, `lastSyncedAt`, `state` and `lastError` with whatever
    /// they were at render time — rolling the cursor back re-walks mail, and
    /// rolling it to `nil` forces a full backfill. Only the signature may
    /// change here.
    public func updateSignature(_ signature: String, accountID: String) {
        guard var account = store.accounts().first(where: { $0.id == accountID }),
              account.signature != signature else { return }
        account.signature = signature
        do {
            try store.saveAccount(account)
        } catch {
            host.log.error("Raven: could not save the signature: \(error)")
        }
    }

    /// Routes a diagnostic line to the host's logger. Views must not `print()`
    /// — a shipped plugin's stdout goes nowhere the user or the host can see.
    public func log(_ message: String) {
        host.log.info(message)
    }

    // MARK: Outbox

    public func refreshOutboxSnapshots() {
        outboxDeadLettered = outbox.deadLettered()
        outboxNeedsReview = outbox.needsReview()
    }

    public func discardOutboxEntry(_ id: UUID) {
        try? outbox.discard(id)
        refreshOutboxSnapshots()
    }

    public func drainOutbox() async {
        await outbox.drain()
        refreshOutboxSnapshots()
    }

    // MARK: Archive search (outside the synced window)

    /// A deliberate, explicit "search all mail" act — never triggered per
    /// keystroke. Delegates to the provider's server-side search
    /// (`MailProvider.searchThreads`), which reaches Gmail's full archive,
    /// not just the locally-synced window `ThreadSearch` filters.
    ///
    /// Every hit is cached locally via `store.upsertThread` so the thread
    /// becomes a normal store row from then on — it opens, renders, and can
    /// be archived/replied like any synced thread, with its body still
    /// fetched lazily exactly as today. That matters because a 6-month-old
    /// hit lands in a month-shard the Inbox's windowed view (`RavenViewModel.
    /// reload`, `RavenMCPOperations.recentMonths`) never loads — caching it
    /// does NOT make it show up in the Inbox list. This is deliberate, not a
    /// gap: `archiveSearchState` is surfaced as its OWN "results from all
    /// mail" list, kept visibly separate from the Inbox's windowed view,
    /// rather than silently blending an archive hit into a list whose whole
    /// contract is "the last 90 days" — the honest presentation the task
    /// calls for. Selecting a hit from that list still works normally
    /// (`RavenViewModel.select`/`store.thread`), since `upsertThread` already
    /// made it a real row.
    ///
    /// Failure is distinguishable from an empty result: `.failed` carries a
    /// short, safe message (never Gmail's raw response body — see
    /// `GmailProvider.perform`'s documentation for why that must never reach
    /// a persisted field) while `.results([])` means the provider actually
    /// ran and genuinely found nothing.
    /// Searches one account, or — with no argument — every attached account,
    /// merging the hits into one date-ordered list via `UnifiedInbox.merge` so
    /// the results read exactly like the unified Inbox does, each row still
    /// attributed to the account it came from.
    ///
    /// With several accounts, `.failed` means EVERY account that was asked
    /// failed. If one account answers and another errors, the answer is
    /// `.results` for what was actually found — silently reporting a total
    /// failure would hide real hits, and reporting a clean success would hide
    /// nothing more than the M0 single-account case already did. A search with
    /// no attached providers at all is `.failed`, not an empty result, exactly
    /// as before.
    public func searchArchive(query: String, accountID: String? = nil) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { archiveSearchState = .idle; return }
        let targets = accountID.map { [$0] } ?? providers.attachedAccountIDs
        guard !targets.isEmpty else {
            archiveSearchState = .failed(Self.archiveSearchFailureMessage(
                MailError.notAuthenticated(accountID: accountID ?? "")))
            return
        }
        archiveSearchState = .searching
        var groups: [[ThreadSummary]] = []
        var failure: String?
        var succeeded = false
        for target in targets {
            guard let provider = providers.provider(for: target) else {
                failure = failure ?? Self.archiveSearchFailureMessage(
                    MailError.notAuthenticated(accountID: target))
                continue
            }
            do {
                let threads = try await provider.searchThreads(query: trimmed, limit: 50)
                for thread in threads {
                    try? store.upsertThread(thread)
                }
                groups.append(threads.map { $0.summary() })
                succeeded = true
            } catch {
                failure = failure ?? Self.archiveSearchFailureMessage(error)
            }
        }
        if !succeeded, let failure {
            archiveSearchState = .failed(failure)
            return
        }
        archiveSearchState = .results(UnifiedInbox.merge(groups))
    }

    /// Clears the last archive search — called when the search field itself
    /// is cleared or edited, so a stale "results from all mail" list never
    /// lingers next to a search string that no longer produced it.
    public func clearArchiveSearch() {
        archiveSearchState = .idle
    }

    /// Maps a thrown error to a short, user-safe message — reusing
    /// `MailError`'s existing cases rather than `String(describing:)`-ing an
    /// arbitrary error, which for `.providerFailed` could echo a Gmail
    /// response body. Never written to `MailAccount.lastError` (that field is
    /// document-backed and persisted); this only ever feeds `archiveSearchState`.
    private static func archiveSearchFailureMessage(_ error: Error) -> String {
        switch error {
        case MailError.notAuthenticated:
            return "No account connected."
        case MailError.rateLimited(let retryAfter):
            return "Gmail rate-limited this search; try again in \(Int(retryAfter))s."
        case MailError.providerFailed(let status, _):
            return "Search all mail failed (status \(status))."
        case MailError.decodingFailed:
            return "Search all mail failed to decode the provider's response."
        default:
            return "Search all mail failed."
        }
    }

    // MARK: Bodies

    /// Returns the cached body if the store already has one, otherwise fetches
    /// it from the provider. The fetch (and the HTML-to-plain-text sanitizing
    /// it triggers inside `GmailMapping.body`, which the brief clocks at
    /// ~0.5s on a ~1MB body) runs off the main actor via `Task.detached` —
    /// this method is `async` precisely so callers await it rather than
    /// blocking the UI while it runs.
    /// The account is resolved from the message's own thread, so with several
    /// accounts connected a body is fetched by the mailbox it actually belongs
    /// to — and cached under that same account, so sign-out purges it.
    public func loadBody(for message: MailMessage) async -> MessageBody? {
        if let cached = store.body(messageID: message.id) { return cached }
        guard let accountID = store.thread(message.threadID)?.accountID,
              let provider = providers.provider(for: accountID) else { return nil }
        do {
            let body = try await Task.detached {
                try await provider.fetchBody(messageID: message.id)
            }.value
            // Attributed to the account that fetched it, so sign-out can purge
            // it even if this message's thread document never lands.
            try? store.saveBody(body, accountID: accountID)
            return body
        } catch {
            host.log.error("RavenRuntime.loadBody failed for \(message.id): \(error)")
            return nil
        }
    }

    // MARK: Attachments

    /// Fetches one attachment's bytes on demand, off the main actor — never
    /// written to a cache directory (see the task report's attachment-fetch
    /// notes). `nil` when there is no attached provider or the fetch fails;
    /// the caller (the Thread surface's chip tap handler) treats that as "try
    /// again later" rather than crashing.
    public func fetchAttachment(_ attachment: MailAttachment, messageID: String,
                                threadID: String) async -> Data? {
        guard let accountID = store.thread(threadID)?.accountID,
              let provider = providers.provider(for: accountID) else { return nil }
        do {
            return try await Task.detached {
                try await provider.fetchAttachment(messageID: messageID,
                                                    attachmentID: attachment.attachmentID)
            }.value
        } catch {
            host.log.error("RavenRuntime.fetchAttachment failed for \(attachment.attachmentID): \(error)")
            return nil
        }
    }

    // MARK: Remote-image opt-in (persisted per sender)

    /// Whether `sender`'s remote images auto-load without the user pressing
    /// "Load images" again — see `RemoteImageAllowList`. Unknown senders
    /// default to blocked; this must never default to `true`.
    public func imagesAllowed(for sender: String) -> Bool {
        RemoteImageAllowList.isAllowed(sender, documents: host.documents)
    }

    /// Persists that `sender`'s images should auto-load from now on.
    public func allowImages(for sender: String) {
        RemoteImageAllowList.allow(sender, documents: host.documents)
    }

    // MARK: Compose (reply/reply-all/forward)

    /// The address of the account that owns `accountID`, so `ReplyComposer` can
    /// exclude it from a reply-all — never mail yourself. Takes the account
    /// explicitly (the caller reads it off the thread being replied to) rather
    /// than guessing at "the" account, which with several connected would
    /// exclude the wrong address and mail the user their own mailbox.
    public func ownAddress(for accountID: String) -> String? {
        store.accounts().first { $0.id == accountID }?.address
    }

    /// Sends a reply/reply-all/forward composed on the Thread surface through
    /// the exact same queue-drain-classify path every other send in this app
    /// uses (`SendAttempt`) — see that type's documentation for why sending
    /// lives in exactly one place. No draft id: a thread reply is not backed
    /// by a `DraftBox` entry.
    public func sendThreadReply(_ message: OutgoingMessage) async throws -> SendAttempt.Result {
        try await SendAttempt.send(message, draftID: nil, outbox: outbox, store: store,
                                   holdUntil: Date().addingTimeInterval(holdWindow),
                                   drain: drainOutbox)
    }

    /// The undo-send hold window applied to every real send this runtime
    /// issues (compose, reply, and — see `RavenMCPOperations`'s `send_draft`
    /// documentation — Sage's `send_draft` too). Configurable from Accounts;
    /// `SendAttempt.defaultHoldWindow` (20s) until the user changes it.
    /// Persisted as a document since it is a preference, not a secret.
    public var holdWindow: TimeInterval {
        get {
            guard let data = host.documents.data(forKey: Self.holdWindowKey),
                  let seconds = try? JSONDecoder().decode(Double.self, from: data)
            else { return SendAttempt.defaultHoldWindow }
            return seconds
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                host.documents.setData(data, forKey: Self.holdWindowKey)
            }
        }
    }
    private static let holdWindowKey = "send-hold-window-seconds"
}
