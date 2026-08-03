import Foundation
import AinkradAppKit

/// Forwards `MailProvider` calls to whichever concrete provider is currently
/// connected, or throws `.notAuthenticated` when there is none yet.
///
/// `Outbox` and `SyncEngine` both take their provider at `init` and hold it
/// for their whole lifetime, but `RavenRuntime` must hand out a working
/// `Outbox` (see `RavenApp.makeMCPServer`'s contract) before any account has
/// ever been connected — there is no real provider to construct it with at
/// that point. This proxy exists so `Outbox` can be built exactly once, in
/// `RavenRuntime.init`, and still start forwarding for real the moment an
/// account is authorized, without `Outbox` itself changing.
///
/// `@unchecked Sendable`, and deliberately NOT `@MainActor`, for the same
/// reason `GmailProvider` is: `MailProvider` is a plain `Sendable` protocol
/// with no actor isolation, so a conformer declared `@MainActor` fails to
/// typecheck ("crosses into main actor-isolated code"). Every actual call
/// runs from `RavenRuntime`, `SyncEngine`, or `Outbox` — all three
/// `@MainActor` — so `current`/`accountID` are in practice only ever touched
/// from that one actor; that invariant is enforced by convention (every call
/// site is `@MainActor`), not by the compiler.
final class RavenProviderProxy: MailProvider, @unchecked Sendable {
    var accountID: String
    var current: MailProvider?

    init(accountID: String) {
        self.accountID = accountID
    }

    private func require() throws -> MailProvider {
        guard let current else { throw MailError.notAuthenticated(accountID: accountID) }
        return current
    }

    func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
        try await require().fetchThreads(since: since, pageToken: pageToken)
    }
    func fetchDelta(cursor: String) async throws -> MailDelta {
        try await require().fetchDelta(cursor: cursor)
    }
    func fetchThread(id: String) async throws -> MailThread {
        try await require().fetchThread(id: id)
    }
    func fetchBody(messageID: String) async throws -> MessageBody {
        try await require().fetchBody(messageID: messageID)
    }
    func fetchLabels() async throws -> [MailLabel] {
        try await require().fetchLabels()
    }
    func applyLabels(_ mutation: LabelMutation) async throws {
        try await require().applyLabels(mutation)
    }
    func send(_ message: OutgoingMessage) async throws -> String {
        try await require().send(message)
    }
    func currentCursor() async throws -> String {
        try await require().currentCursor()
    }
}

/// One instance per `HostServices`, so the on-screen UI and the MCP server
/// (`RavenApp.makeMCPServer`) drive the SAME store, outbox, and account state
/// rather than two detached copies — `RavenApp` caches one runtime per host
/// and hands it to both.
///
/// M0 supports one connected account at a time: `RavenViewModel` and
/// `RavenMCPOperations` both already key off `store.accounts().first`, and
/// `Outbox`/`SyncEngine` are each built around a single provider, so this
/// mirrors that rather than introducing multi-account plumbing nothing else
/// here is ready for.
@MainActor @Observable public final class RavenRuntime {
    public let store: DocumentMailStore
    public let outbox: Outbox
    public let model: RavenViewModel

    private let host: HostServices
    private let providerProxy: RavenProviderProxy
    private var auth: GmailAuth?
    /// Not `private` — `RavenAgentBridgeTests` swaps this for one built
    /// around a scriptable `FakeMailProvider` to exercise `syncOnce()`'s
    /// failure path without a live network. Still only ever mutated from
    /// `@MainActor` call sites in this file, exactly as before.
    var syncEngine: SyncEngine?
    /// The running poll loop started in `init` and cancelled in `teardown()`.
    /// Not resumed once cancelled — a closed instance must stop calling
    /// Gmail, not just stop being observed.
    private var syncTask: Task<Void, Never>?
    /// The detached 90-day backfill kicked off by `connectAccount`/
    /// `resyncFromScratch`. Cancelled (never resumed) in `teardown()`, exactly
    /// like `syncTask` — a closed instance must stop calling Gmail — and also
    /// cancelled when the account it belongs to is signed out, so a backfill
    /// for an account that no longer exists locally cannot keep writing to
    /// the store underneath it.
    private var backfillTask: Task<Void, Never>?
    /// Guards `resyncFromScratch` against a second concurrent walk. Set
    /// `true` synchronously inside `startBackfill()` — before the `Task` it
    /// creates has had any chance to actually run — and reset `false` at the
    /// end of `runBackfill()`, on sign-out, and on teardown. See
    /// `resyncFromScratch`'s documentation for why this refuses a second
    /// call rather than cancelling-and-restarting: `SyncEngine.backfill()`
    /// never checks `Task.isCancelled`, so cancelling the wrapper `Task`
    /// alone cannot be trusted to stop a real network walk already in
    /// flight, and two overlapping walks writing into the same store is
    /// exactly what must never happen.
    private var isBackfilling = false
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

    public private(set) var syncState: SyncState = .idle
    /// Surfaced separately from `syncState` on purpose — see `SyncEngine`'s
    /// own documentation of `lastBackfillTruncated`: it is a plain flag, not
    /// a `SyncState` case, so a view that renders only `syncState` would
    /// silently miss it.
    public private(set) var lastBackfillTruncated = false
    public private(set) var lastSyncError: String? {
        // Mirrored into `model` (rather than the view reading `runtime`
        // directly) so `InboxSurface` can tell "sync failed" apart from
        // "nothing synced yet" from `model` alone, matching how it already
        // gets everything else (summaries, selection) through the view model.
        didSet { model.lastSyncError = lastSyncError }
    }
    public private(set) var outboxDeadLettered: [OutboxEntry] = []
    /// Entries whose outcome is unknown because a previous process died
    /// mid-send — see `Outbox.needsReview()`. Never auto-resolved.
    public private(set) var outboxNeedsReview: [OutboxEntry] = []

    public init(host: HostServices) {
        self.host = host
        let store = DocumentMailStore(documents: host.documents)
        self.store = store

        let accountID = store.accounts().first?.id ?? ""
        let proxy = RavenProviderProxy(accountID: accountID)
        self.providerProxy = proxy
        let outbox = Outbox(documents: host.documents, provider: proxy,
                            accountID: accountID.isEmpty ? nil : accountID)
        self.outbox = outbox
        self.model = RavenViewModel(store: store, outbox: outbox)

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
            if let account = store.accounts().first {
                attach(provider: GmailProvider(accountID: account.id, auth: auth), accountID: account.id)
            }
        } else if let idData = host.documents.data(forKey: Self.clientIDKey),
           let clientID = String(data: idData, encoding: .utf8),
           let clientSecret = host.secrets.secret(forKey: Self.clientSecretKey) {
            // Fallback for a developer build with no Config/oauth-client.json:
            // the manually-entered credentials saved via `saveCredentials`.
            let auth = GmailAuth(secrets: host.secrets, clientID: clientID, clientSecret: clientSecret)
            self.auth = auth
            if let account = store.accounts().first {
                attach(provider: GmailProvider(accountID: account.id, auth: auth), accountID: account.id)
            }
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
        backfillTask?.cancel()
        backfillTask = nil
        isBackfilling = false
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
        if let account = store.accounts().first {
            attach(provider: GmailProvider(accountID: account.id, auth: auth), accountID: account.id)
        }
    }

    // MARK: Accounts

    public var accounts: [MailAccount] { store.accounts() }

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
        model.accountID = accountID
        model.reload()
        startBackfill()
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
    private func startBackfill() {
        backfillTask?.cancel()
        isBackfilling = true
        backfillTask = Task { [weak self] in
            await self?.runBackfill()
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
        if providerProxy.accountID == accountID {
            // A backfill in flight for this account must stop too — it would
            // otherwise keep fetching and writing threads for an account this
            // instance no longer has a provider for.
            backfillTask?.cancel()
            backfillTask = nil
            isBackfilling = false
            providerProxy.current = nil
            syncEngine = nil
            outbox.accountID = nil
        }
        if model.accountID == accountID {
            model.accountID = store.accounts().first?.id
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
    public func resyncFromScratch() {
        guard !isBackfilling else {
            host.log.info("Raven: resync already in progress; ignoring the new request.")
            return
        }
        startBackfill()
    }

    /// Whether a backfill (from `connectAccount` or `resyncFromScratch`) is
    /// currently walking pages. Exposed read-only so a caller — tests in
    /// particular — can confirm a `resyncFromScratch()` call was refused
    /// rather than silently starting a second walk.
    public var isResyncing: Bool { isBackfilling }

    public func syncNow() async {
        guard let syncEngine else { return }
        do {
            try await syncEngine.syncDelta()
            lastSyncError = nil
        } catch {
            lastSyncError = String(describing: error)
        }
        syncState = syncEngine.state
        model.reload()
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
    func syncOnce() async {
        guard let syncEngine else { return }
        do {
            try await syncEngine.syncDelta()
            lastSyncError = nil
        } catch {
            lastSyncError = String(describing: error)
        }
        syncState = syncEngine.state
        if case .failed(let message) = syncState {
            lastSyncError = message
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
    private func runBackfill() async {
        defer { isBackfilling = false }
        guard let syncEngine else { return }
        do {
            try await syncEngine.backfill()
            lastSyncError = nil
        } catch {
            lastSyncError = String(describing: error)
        }
        syncState = syncEngine.state
        lastBackfillTruncated = syncEngine.lastBackfillTruncated
        model.reload()
    }

    /// Mirrors `syncEngine.state`/`lastBackfillTruncated` into this
    /// `@Observable` instance's own properties and reloads `model`. Wired as
    /// `SyncEngine.onChange` by `attach()` so every page of a backfill (and
    /// every `syncDelta()` state transition) pushes here instead of the
    /// Accounts surface having to poll for it.
    private func mirrorSyncEngineState() {
        guard let syncEngine else { return }
        syncState = syncEngine.state
        lastBackfillTruncated = syncEngine.lastBackfillTruncated
        model.reload()
    }

    private func attach(provider: GmailProvider, accountID: String) {
        providerProxy.accountID = accountID
        providerProxy.current = provider
        // Stamps everything queued from here on with this account, so it can
        // never be transmitted through a different one later.
        outbox.accountID = accountID
        let engine = SyncEngine(store: store, provider: provider, accountID: accountID)
        engine.onChange = { [weak self] in self?.mirrorSyncEngineState() }
        syncEngine = engine
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

    // MARK: Bodies

    /// Returns the cached body if the store already has one, otherwise fetches
    /// it from the provider. The fetch (and the HTML-to-plain-text sanitizing
    /// it triggers inside `GmailMapping.body`, which the brief clocks at
    /// ~0.5s on a ~1MB body) runs off the main actor via `Task.detached` —
    /// this method is `async` precisely so callers await it rather than
    /// blocking the UI while it runs.
    public func loadBody(for message: MailMessage) async -> MessageBody? {
        if let cached = store.body(messageID: message.id) { return cached }
        guard let provider = providerProxy.current else { return nil }
        do {
            let body = try await Task.detached {
                try await provider.fetchBody(messageID: message.id)
            }.value
            // Attributed to the account that fetched it, so sign-out can purge
            // it even if this message's thread document never lands.
            try? store.saveBody(body, accountID: providerProxy.accountID)
            return body
        } catch {
            host.log.error("RavenRuntime.loadBody failed for \(message.id): \(error)")
            return nil
        }
    }
}
