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
    private var syncEngine: SyncEngine?

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
    public private(set) var lastSyncError: String?
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
        let outbox = Outbox(documents: host.documents, provider: proxy)
        self.outbox = outbox
        self.model = RavenViewModel(store: store, outbox: outbox)

        if let idData = host.documents.data(forKey: Self.clientIDKey),
           let clientID = String(data: idData, encoding: .utf8),
           let clientSecret = host.secrets.secret(forKey: Self.clientSecretKey) {
            let auth = GmailAuth(secrets: host.secrets, clientID: clientID, clientSecret: clientSecret)
            self.auth = auth
            if let account = store.accounts().first {
                attach(provider: GmailProvider(accountID: account.id, auth: auth), accountID: account.id)
            }
        }
        model.reload()
        refreshOutboxSnapshots()
    }

    // MARK: Credentials

    /// The client id currently saved, if any — safe to show back in the field
    /// the user typed it into. There is deliberately no equivalent getter for
    /// the secret; see `clientSecretKey`.
    public var savedClientID: String? {
        host.documents.data(forKey: Self.clientIDKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    public var hasCredentials: Bool { auth != nil }

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

    /// Runs the loopback OAuth flow, saves the resulting account, and kicks
    /// off its first backfill. `onAuthorizationURL` lets the caller present
    /// the URL if the browser doesn't visibly pop (see `GmailAuth.authorize`).
    public func connectAccount(onAuthorizationURL: (@Sendable (URL) -> Void)? = nil) async throws {
        guard let auth else { throw MailError.notAuthenticated(accountID: "") }
        let (accountID, address) = try await auth.authorize(onAuthorizationURL: onAuthorizationURL)
        try store.saveAccount(MailAccount(id: accountID, provider: .gmail, address: address,
                                          displayName: address, state: .syncing))
        attach(provider: GmailProvider(accountID: accountID, auth: auth), accountID: accountID)
        model.accountID = accountID
        await runBackfill()
    }

    public func signOut(_ accountID: String) {
        auth?.signOut(accountID: accountID)
        try? store.removeAccount(accountID)
        if providerProxy.accountID == accountID {
            providerProxy.current = nil
            syncEngine = nil
        }
        if model.accountID == accountID {
            model.accountID = store.accounts().first?.id
        }
        model.reload()
    }

    /// Re-walks the full sync window from scratch. `SyncEngine.backfill()`
    /// always does a fresh page walk (not a delta against the stored cursor),
    /// so calling it again IS the "resync from scratch" the Accounts surface
    /// offers — no separate code path needed.
    public func resyncFromScratch() async {
        await runBackfill()
    }

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

    private func runBackfill() async {
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

    private func attach(provider: GmailProvider, accountID: String) {
        providerProxy.accountID = accountID
        providerProxy.current = provider
        syncEngine = SyncEngine(store: store, provider: provider, accountID: accountID)
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
            try? store.saveBody(body)
            return body
        } catch {
            host.log.error("RavenRuntime.loadBody failed for \(message.id): \(error)")
            return nil
        }
    }
}
