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
/// state. `auth` and the credential keys are the one thing that did NOT move
/// and are still `private` to this file.
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
    /// Stays `private` — this is the credential path. Nothing outside this file
    /// may read or replace it, which is why `attachStoredAccounts(auth:)` takes
    /// the value as an argument instead of reading this property.
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
        self.appearanceStore = RavenAppearanceStore(documents: host.documents)
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
