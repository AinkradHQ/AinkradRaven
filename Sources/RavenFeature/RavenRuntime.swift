import Foundation
import AinkradAppKit

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
///
/// **This file is the whole of the runtime's state.** Every stored property,
/// the initializer, `teardown()`, the credential path and the account lifecycle
/// live here; the behaviour that operates on that state is split into
/// extensions purely for length, and each names what it may mutate:
///
/// - `RavenRuntime+Sync.swift` — the poll loop, delta syncs, backfills, engine
///   attachment.
/// - `RavenRuntime+ArchiveSearch.swift` — "search all mail" and its state.
/// - `RavenRuntime+Preferences.swift` — the document-backed preferences (rules,
///   hold window, remote-image opt-in, signature) and `log`.
/// - `RavenRuntime+Content.swift` — on-demand body/attachment fetches and the
///   thread-reply send path.
///
/// The split is deliberately NOT a set of collaborator objects. `RavenRuntime`
/// stays the single object the app hands around, and the published per-account
/// dictionaries below keep their `private(set)`: the extensions mutate them
/// only through the named mutators in "State mutation" at the bottom of this
/// file, so there is exactly one place to look to find every write to sync
/// state. The credential path no longer lives here at all: `ProviderFactory`
/// owns it, along with every `MailProvider` construction, so this file names no
/// provider and no auth type.
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

    /// Surface translucency/blur, observable so the settings slider repaints
    /// the mail panes live — see `RavenAppearanceStore` for why it is its own
    /// object rather than a computed property here like `holdWindow`.
    public let appearanceStore: RavenAppearanceStore

    /// Transient settings-form text (the OAuth client id/secret pair) that must
    /// survive the host rebuilding the settings catalog on every render pass.
    /// See `RavenSettingsDraft`.
    public let settingsDraft = RavenSettingsDraft()

    /// Internal, not private, because every extension listed in this type's
    /// documentation reads `host.documents`/`host.log` through it. Still
    /// invisible outside `RavenFeature`.
    let host: HostServices
    /// The only construction site for any `MailProvider`, and the credential
    /// path with it — see `ProviderFactory`. Replaces M0's single
    /// `auth: GmailAuth?`, which made the runtime a Gmail-specific object.
    /// Internal rather than private so `attachStoredAccounts()` in
    /// `RavenRuntime+Sync.swift` can build providers through it; the factory
    /// exposes no token and no secret getter, so this is narrower than the
    /// `GmailAuth` it replaces despite the wider visibility.
    let providerFactory: ProviderFactory
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
    ///
    /// Internal rather than private so `startSyncTimer` can live in
    /// `RavenRuntime+Sync.swift`. It is an implementation detail either way —
    /// never `public`, so no caller outside this module can reach it.
    var syncTask: Task<Void, Never>?
    /// The detached 90-day backfills kicked off by `connectAccount`/
    /// `resyncFromScratch`, one per account. Cancelled (never resumed) in
    /// `teardown()`, exactly like `syncTask` — a closed instance must stop
    /// calling Gmail — and also cancelled for the one account that is signed
    /// out, so a backfill for an account that no longer exists locally cannot
    /// keep writing to the store underneath it while other accounts' backfills
    /// continue untouched.
    var backfillTasks: [String: Task<Void, Never>] = [:]
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
    var backfillingAccounts: Set<String> = []
    /// One `IMAPIdleWatcher` per IMAP account, and the task running it. No entry at
    /// all for Gmail or Apple Mail — see `startIdleWatcher`.
    ///
    /// The presence of a key is what makes starting one IDEMPOTENT, and that is
    /// load-bearing rather than defensive: `attach(provider:accountID:)` genuinely
    /// runs more than once for the same account within one runtime
    /// (`attachStoredAccounts()` from `init` and again from `saveCredentials`,
    /// plus `connectAccount`'s direct call), and a second watcher would mean two
    /// IDLE connections and two leases for one mailbox — the same unbalanced-acquire
    /// shape as the `startAccessing` bug Task 1 fixed.
    var idleWatchers: [String: IMAPIdleWatcher] = [:]
    var idleTasks: [String: Task<Void, Never>] = [:]
    /// Test-only seam: the clock every IDLE watcher this runtime starts is given;
    /// `nil` means the production `IMAPIdleSystemClock`. The same kind of seam as
    /// `attachTestProvider` — internal, never `public`, read at one place
    /// (`startIdleWatcher`) — and it exists because proving a notification reaches
    /// `syncNow` would otherwise mean sleeping out the one-second coalesce window.
    var idleClockOverride: (any IMAPIdleClock)?
    private var contextToken: PluginContextToken?
    private var actionTokens: [AgentActionToken] = []

    /// Read by `holdWindow` in `RavenRuntime+Preferences.swift`, hence internal
    /// rather than private. Not a secret — a preference.
    static let holdWindowKey = "send-hold-window-seconds"

    /// Per-account sync state. Independently observable, so one account's
    /// failure is visible as that account's failure rather than as a single
    /// app-wide status that whichever account synced last happens to own.
    public private(set) var syncStates: [String: SyncState] = [:]
    /// Per-account most recent sync/backfill failure.
    public private(set) var syncErrors: [String: String] = [:]
    /// The accounts whose most recent backfill stopped early.
    public private(set) var truncatedBackfills: Set<String> = []
    /// Per-IMAP-account near-push status; absent for the kinds that never idle.
    ///
    /// NOT merged into `syncErrors`, for two reasons: `IDLE` being unavailable is a
    /// degradation rather than a failure (the poll still runs), and `syncAccount`
    /// CLEARS `syncErrors` on every successful pass — so a terminal IDLE outcome
    /// written there would be erased by the next tick and never seen.
    public private(set) var pushStates: [String: RavenPushState] = [:]

    // The read side of these four mirrors — the per-account accessors and the
    // app-wide `syncState`/`lastBackfillTruncated` roll-ups — lives in
    // `RavenRuntime+Status.swift`. The WRITE side stays in this file, under
    // "State mutation", because `private(set)` is file-scoped; see that section.

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
        // Built before anything that captures `self` (the outbox wake below),
        // because a `let` must be initialized before `self` may escape.
        self.providerFactory = ProviderFactory(host: host)
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
        self.appearanceStore = RavenAppearanceStore(documents: host.documents)
        // The one-shot wake `Outbox` schedules for the earliest held/
        // scheduled entry calls back into `drainOutbox()` (not `outbox.
        // drain()` directly) so a wake also refreshes the dead-letter/
        // needs-review snapshots the Accounts surface renders — see
        // `Outbox.onWake`'s own documentation.
        outbox.onWake = { [weak self] in await self?.drainOutbox() }

        // Credential resolution (baked-in vs. manually saved) and provider
        // construction both live in `ProviderFactory` now (built at the top of
        // this initializer), so this file names neither `GmailAuth` nor
        // `GmailProvider`. Every stored account is attached through it,
        // whatever its kind — an account whose kind this build cannot build is
        // logged and skipped inside `attachStoredAccounts()`, leaving the
        // others attached.
        attachStoredAccounts()
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
    public func teardown() {
        syncTask?.cancel()
        syncTask = nil
        outbox.teardownWake()
        for task in backfillTasks.values { task.cancel() }
        backfillTasks = [:]
        backfillingAccounts = []
        // Every IDLE connection goes too. A watcher left running holds a lease and
        // an authenticated socket for a runtime that has otherwise stopped — the
        // same "a per-instance runtime that never tears down is a leak, not a
        // cache" reasoning as `syncTask`, except an IDLE socket also occupies one
        // of the server's per-user connection slots for up to 29 minutes.
        stopAllIdleWatchers()
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
    public var savedClientID: String? { providerFactory.savedClientID }

    public var hasCredentials: Bool { providerFactory.hasGmailCredentials }

    /// Whether `BakedOAuthCredentials` supplied both values at build time
    /// (see `scripts/generate-oauth-credentials.sh`). When true, the
    /// Accounts surface shows only the Connect button and the connected
    /// account — no manual client id/secret fields, since there is nothing
    /// for the user to enter.
    public var isCredentialsBaked: Bool { providerFactory.isCredentialsBaked }

    /// Whether Connect could possibly succeed: credentials are either baked
    /// into the app (the shipped case) or have been saved by the user.
    /// Enabled-but-guaranteed-to-fail is worse than disabled.
    ///
    /// Lives on the runtime rather than in a view because BOTH settings
    /// surfaces need it now — the catalog's Connect action and the fallback
    /// pane's button — and two copies of this rule is how one of them ends up
    /// offering a button that cannot work. Note it asks whether credentials are
    /// SAVED, not whether something is typed: on the catalog surface saving is
    /// its own explicit action (`Save client credentials`), so "typed but not
    /// saved" is no longer a state Connect should accept.
    public var canConnectAccount: Bool { isCredentialsBaked || hasCredentials }

    /// Unchanged semantics: the id is persisted as a document, the secret goes
    /// to `host.secrets` only, and every stored account is re-attached with the
    /// new client. Both halves now happen inside `ProviderFactory`, which is
    /// the only thing that changed here.
    public func saveCredentials(clientID: String, clientSecret: String) {
        providerFactory.saveGmailCredentials(clientID: clientID, clientSecret: clientSecret)
        attachStoredAccounts()
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

    /// True when `accountID`'s attached provider declares `.readOnly` (an
    /// imported Apple Mail mailbox, which has no transport to send or mutate
    /// through). `false` for an account with no provider attached at all —
    /// callers that need "attached AND read-write" already check attachment
    /// separately (`composingAccountID`, `accounts`), so this only answers
    /// the capability question.
    public func isReadOnly(accountID: String) -> Bool {
        providers.provider(for: accountID)?.capabilities == .readOnly
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
    ///
    /// `kind` defaults to `.gmail`, which is the only kind with an interactive
    /// flow today — the existing Connect button therefore behaves exactly as
    /// before. Both the sign-in and the provider come from `ProviderFactory`,
    /// so the account's kind is now recorded from the argument rather than
    /// hardcoded, and a kind whose flow does not exist yet fails with
    /// `MailError.unsupportedProvider` *before* anything is saved.
    public func connectAccount(kind: MailAccount.ProviderKind = .gmail,
                               onAuthorizationURL: (@Sendable (URL) -> Void)? = nil) async throws {
        let (accountID, address) = try await providerFactory.authorize(
            kind: kind, onAuthorizationURL: onAuthorizationURL)
        let account = MailAccount(id: accountID, provider: kind, address: address,
                                  displayName: address, state: .syncing)
        try store.saveAccount(account)
        attach(provider: try providerFactory.makeProvider(for: account), accountID: accountID)
        // Deliberately does NOT scope the Inbox to the account just added:
        // connecting a second mailbox must not hide the first one. The unified
        // list (`model.accountID == nil`) covers every account; a per-account
        // filter is the user's choice, not a side effect of signing in.
        model.reload()
        startBackfill(accountID: accountID)
    }

    /// Signing out must leave nothing of the account behind. Four things go,
    /// in this order:
    ///
    /// 1. every credential the factory holds for the account — the Gmail
    ///    refresh token, and an Apple Mail import's directory bookmark
    ///    (`providerFactory.signOut`);
    /// 2. every queued outbox entry for the account — otherwise, because the
    ///    outbox transmits through whatever provider is attached *now*, a send
    ///    queued for this account would go out from the next account someone
    ///    connects. `OutboxEntry.accountID` blocks that even if this purge is
    ///    somehow missed; the purge is what stops it lingering at all;
    /// 3. every local document — threads, bodies, index shards, labels, and
    ///    the account row. Leaving the mail readable on disk after the user
    ///    has disconnected the account is not a cache;
    /// 4. the account's IDLE connection, if it is an IMAP account with one — see
    ///    `stopIdleWatcher`.
    ///
    /// Every step is scoped to exactly ONE account: with several connected,
    /// signing out of A must leave B's mail, labels, bodies and queued sends
    /// completely intact. `store.purge` is already account-keyed (its month
    /// registry, body index and label document are all per-account), and
    /// `outbox.purge` only drops entries stamped with this account; what this
    /// method must not do — and no longer does — is tear down the shared
    /// provider/engine/backfill state, because that is now per account too.
    public func signOut(_ accountID: String) {
        providerFactory.signOut(accountID: accountID)
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
        // 4. the account's IDLE connection. An unstopped watcher holds a lease and
        //    an authenticated socket for an account whose mail, credential and row
        //    have just been deleted, and its next notification would call `syncNow`
        //    for an account with no provider.
        stopIdleWatcher(accountID: accountID)
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

    // MARK: State mutation

    /// The complete set of writes to this type's published state that happen
    /// outside this file.
    ///
    /// Swift's `private(set)` is file-scoped, so an extension in another file
    /// cannot assign to `syncStates`/`syncErrors`/`truncatedBackfills`/
    /// `archiveSearchState` — and widening them to `internal(set)` would hand
    /// every view and every MCP operation in `RavenFeature` blanket write
    /// access to the sync state, which is exactly the second source of truth a
    /// file split must not create. These named mutators are the narrower
    /// alternative: the setters stay closed, each write is a documented
    /// operation on ONE account rather than an assignment to a whole
    /// dictionary, and this section is the single place to look to enumerate
    /// every mutation the extensions can perform.

    /// Records `accountID`'s sync state. Called from `syncAccount`,
    /// `runBackfill` and `mirrorSyncEngineState`.
    func setSyncState(_ state: SyncState, for accountID: String) {
        syncStates[accountID] = state
    }

    /// Records (or clears, with `nil`) `accountID`'s most recent sync failure.
    /// Per-account on purpose: one account's failure must never overwrite
    /// another's.
    func setSyncError(_ message: String?, for accountID: String) {
        syncErrors[accountID] = message
    }

    /// Records (or clears, with `nil`) `accountID`'s near-push status. Called only
    /// from the IDLE lifecycle in `RavenRuntime+Sync.swift`.
    func setPushState(_ state: RavenPushState?, for accountID: String) {
        pushStates[accountID] = state
    }

    /// Records whether `accountID`'s most recent backfill stopped early.
    func setTruncated(_ truncated: Bool, for accountID: String) {
        if truncated { truncatedBackfills.insert(accountID) }
        else { truncatedBackfills.remove(accountID) }
    }

    /// Recomputes the one-line roll-up from the per-account errors. Ordered by
    /// account id so the line shown is deterministic rather than dependent on
    /// which account's sync finished last, and `nil` only when NO account is
    /// currently failing.
    ///
    /// The sole writer of `lastSyncError`, which is why that property's
    /// `didSet` mirror into `model` cannot be bypassed.
    func refreshAggregateSyncError() {
        lastSyncError = syncErrors.keys.sorted().compactMap { syncErrors[$0] }.first
    }

    /// The only write to `archiveSearchState`. `RavenRuntime+ArchiveSearch.swift`
    /// is its only caller.
    func setArchiveSearchState(_ state: ArchiveSearchState) {
        archiveSearchState = state
    }
}
