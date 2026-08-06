import Foundation
import AinkradAppKit

/// The one place a `MailProvider` is constructed.
///
/// M0 built `GmailProvider` inline inside `RavenRuntime` and held a single
/// `GmailAuth`, so "multi-account" meant multiple *Gmail* accounts: adding a
/// second backend would have meant a second inline construction site, a second
/// credential property, and a second copy of the "which account gets which
/// provider" decision. This type owns that decision instead —
/// `(MailAccount.ProviderKind, MailAccount, HostServices) → MailProvider` — and
/// `RavenRuntime` no longer names a provider or an auth type at all.
///
/// Two rules it exists to keep:
///
/// 1. **A kind this build cannot construct is a per-account failure, never an
///    app-wide one.** `makeProvider` throws `MailError.unsupportedProvider`
///    for that one account; `RavenRuntime.attachStoredAccounts` logs it and
///    carries on with the rest. Combined with `ProviderKind.unsupported`'s
///    lenient decode, one bad `accounts` row can neither fail the document nor
///    detach a sibling mailbox.
/// 2. **The credential path stays here.** `GmailAuth` is constructed in this
///    file and nowhere else, and the refresh token it manages still reaches
///    `host.secrets` only — this type never writes a token, an access token or
///    a client secret through `host.documents`.
@MainActor public final class ProviderFactory {
    private let host: HostServices

    /// Gmail's OAuth client, `nil` when no client id/secret pair is available
    /// (neither baked in at build time nor saved by the user). Deliberately
    /// one instance for every Gmail account: each account's refresh token is
    /// looked up inside `GmailAuth` under that account's id.
    private var gmailAuth: GmailAuth?

    /// Microsoft Graph's OAuth client, `nil` when no Azure app registration is
    /// available (neither baked in at build time nor saved by the user). One
    /// instance for every Graph account, exactly like `gmailAuth`.
    ///
    /// **`nil` is a supported state, not a failure.** It is what a build with
    /// no Azure registration has — which is every build today — and it must
    /// degrade to "Microsoft accounts are not configured" and NOTHING else:
    /// the plugin loads, `attachStoredAccounts()` keeps attaching every Gmail,
    /// IMAP and Apple Mail account, and only a `.graph` account fails, by id.
    private var graphAuth: GraphAuth?

    /// Not a credential — the OAuth client id is only ever a lookup key
    /// against Google, and the user needs to see what they typed to fix a
    /// typo. Persisted as a document, unlike the secret below.
    static let clientIDKey = "gmail-client-id"
    /// The client secret IS a credential (see `GmailAuth`'s own documentation
    /// of the same point). Read from and written to `host.secrets` ONLY.
    static let clientSecretKey = "gmail-client-secret"

    /// The Azure application (client) id. Not a credential — like Google's, it
    /// is only a lookup key, so it is a document.
    static let azureClientIDKey = "graph-client-id"
    /// The Azure directory (tenant) id, or absent for the multi-tenant
    /// `common` endpoint. Not a credential either.
    static let azureTenantIDKey = "graph-tenant-id"
    /// A confidential registration's secret IS a credential. `host.secrets`
    /// ONLY. A public (desktop) registration has none, and that is the normal
    /// case — see `GraphAuth.init`.
    static let azureClientSecretKey = "graph-client-secret"

    /// Production always resolves Apple Mail bookmarks `.withSecurityScope`.
    /// Tests run outside an App Sandbox, where that option is documented to be
    /// unusable, and pass `false` — the same seam, for the same reason, as
    /// `MailDirectoryBookmark.create(for:securityScoped:)`.
    private let securityScopedBookmarks: Bool

    public convenience init(host: HostServices) {
        self.init(host: host, securityScopedBookmarks: true)
    }

    /// `internal`, not `public`, and that is deliberate: this is the test seam,
    /// and a `public` initialiser with a defaulted `securityScopedBookmarks`
    /// lets a future caller outside this module turn security scoping off
    /// without saying so at the call site. The only supported way in from
    /// outside is the initialiser above, which cannot.
    init(host: HostServices, securityScopedBookmarks: Bool) {
        self.host = host
        self.securityScopedBookmarks = securityScopedBookmarks
        gmailAuth = Self.makeGmailAuth(host: host)
        graphAuth = Self.makeGraphAuth(host: host)
    }

    /// Baked credentials (see `BakedOAuthCredentials`) are preferred over
    /// anything the user typed in manually — that is the whole point of baking
    /// them in: the Accounts surface should need to show only a Connect
    /// button. `BakedOAuthCredentials.clientSecret` is passed straight into
    /// `GmailAuth` and never written to `host.secrets` or `host.documents`,
    /// keeping the number of at-rest copies of that secret to the one already
    /// compiled into the binary.
    private static func makeGmailAuth(host: HostServices) -> GmailAuth? {
        if let clientID = BakedOAuthCredentials.clientID,
           let clientSecret = BakedOAuthCredentials.clientSecret {
            return GmailAuth(secrets: host.secrets, clientID: clientID, clientSecret: clientSecret)
        }
        // Fallback for a developer build with no Config/oauth-client.json: the
        // manually-entered credentials saved via `saveGmailCredentials`.
        guard let idData = host.documents.data(forKey: clientIDKey),
              let clientID = String(data: idData, encoding: .utf8),
              let clientSecret = host.secrets.secret(forKey: clientSecretKey) else { return nil }
        return GmailAuth(secrets: host.secrets, clientID: clientID, clientSecret: clientSecret)
    }

    /// Graph's counterpart to `makeGmailAuth`, and deliberately the same shape:
    /// baked credentials first, then the manually-saved fallback.
    ///
    /// **The client id alone is sufficient**, unlike Gmail's, where an absent
    /// secret means the Desktop client cannot exchange anything. An Azure
    /// desktop registration is a public client with no secret at all, so
    /// requiring one here would make the supported configuration look
    /// unconfigured. The tenant is optional and defaults to `common`.
    private static func makeGraphAuth(host: HostServices) -> GraphAuth? {
        // The secret, when there is one, is passed straight through and never
        // written to `host.documents` — same rule as Gmail's.
        if let clientID = BakedOAuthCredentials.azureClientID {
            return GraphAuth(secrets: host.secrets, clientID: clientID,
                             clientSecret: BakedOAuthCredentials.azureClientSecret,
                             tenantID: BakedOAuthCredentials.azureTenantID
                                ?? GraphAuth.commonTenant)
        }
        guard let idData = host.documents.data(forKey: azureClientIDKey),
              let clientID = String(data: idData, encoding: .utf8),
              !clientID.isEmpty else { return nil }
        let tenantID = host.documents.data(forKey: azureTenantIDKey)
            .flatMap { String(data: $0, encoding: .utf8) }
        return GraphAuth(secrets: host.secrets, clientID: clientID,
                         clientSecret: host.secrets.secret(forKey: azureClientSecretKey),
                         tenantID: (tenantID?.isEmpty == false) ? tenantID! : GraphAuth.commonTenant)
    }

    // MARK: Credentials

    /// Whether a Gmail OAuth client exists, i.e. whether `authorize(kind:
    /// .gmail)` could possibly succeed.
    public var hasGmailCredentials: Bool { gmailAuth != nil }

    /// Whether an Azure app registration exists, i.e. whether a Microsoft
    /// account could be connected at all. `false` is the honest "not
    /// configured" answer the Accounts surface shows instead of a Connect
    /// button that could only ever fail.
    public var hasGraphCredentials: Bool { graphAuth != nil }

    public var savedClientID: String? {
        BakedOAuthCredentials.clientID
            ?? host.documents.data(forKey: Self.clientIDKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Whether `BakedOAuthCredentials` supplied both values at build time.
    public var isCredentialsBaked: Bool {
        BakedOAuthCredentials.clientID != nil && BakedOAuthCredentials.clientSecret != nil
    }

    /// Saves a manually-entered client id/secret pair and rebuilds the Gmail
    /// client from it. The id goes to `host.documents`, the secret to
    /// `host.secrets` — never the other way round.
    public func saveGmailCredentials(clientID: String, clientSecret: String) {
        guard let data = clientID.data(using: .utf8) else { return }
        host.documents.setData(data, forKey: Self.clientIDKey)
        host.secrets.setSecret(clientSecret, forKey: Self.clientSecretKey)
        gmailAuth = GmailAuth(secrets: host.secrets, clientID: clientID,
                              clientSecret: clientSecret)
    }

    // MARK: Authorization

    /// Runs `kind`'s interactive sign-in and returns the account it identifies.
    ///
    /// Only `.gmail` has a *browser* flow, and this function is that flow.
    ///
    /// `.imap` still throws here, and that is the correct answer rather than a gap
    /// Task 16 forgot to close: an IMAP account is not authorized, it is
    /// *configured*. There is no redirect to wait for and no identity the server
    /// hands back — the address, the servers and the password all come from the
    /// form, so the account is added through `RavenRuntime.addIMAPAccount` /
    /// `saveIMAPAccount`, exactly as `.appleMail` is added through
    /// `saveAppleMailDirectory`. Routing it through an `onAuthorizationURL`
    /// callback that would never fire is the shape to avoid.
    ///
    /// `.graph` is the second browser flow, and it is the SAME flow: both
    /// cases below run `Auth/LoopbackCallbackListener` + `Auth/PKCE` +
    /// `Auth/OAuthTokenClient`, differing only in the endpoints and scopes
    /// their auth type configures. A build with no Azure registration answers
    /// `.notAuthenticated` here rather than pretending it could connect —
    /// callers test `hasGraphCredentials` first to avoid offering the button
    /// at all.
    public func authorize(kind: MailAccount.ProviderKind,
                          onAuthorizationURL: (@Sendable (URL) -> Void)? = nil)
        async throws -> (accountID: String, address: String) {
        switch kind {
        case .gmail:
            guard let gmailAuth else { throw MailError.notAuthenticated(accountID: "") }
            return try await gmailAuth.authorize(onAuthorizationURL: onAuthorizationURL)
        case .graph:
            guard let graphAuth else { throw MailError.notAuthenticated(accountID: "") }
            return try await graphAuth.authorize(onAuthorizationURL: onAuthorizationURL)
        case .imap, .appleMail, .unsupported:
            throw MailError.unsupportedProvider(kind: kind.identifier, accountID: "")
        }
    }

    // MARK: Construction

    /// The provider for one stored account, or a throw naming exactly which
    /// account could not be built. Never returns `nil`: a caller that gets a
    /// provider gets a usable one, and a caller that gets an error knows the
    /// account id to attribute it to.
    public func makeProvider(for account: MailAccount) throws -> MailProvider {
        switch account.provider {
        case .gmail:
            guard let gmailAuth else {
                throw MailError.notAuthenticated(accountID: account.id)
            }
            return GmailProvider(accountID: account.id, auth: gmailAuth)
        case .appleMail:
            return try makeAppleMailProvider(for: account)
        case .imap:
            return try makeIMAPProvider(for: account)
        case .graph:
            // No Azure registration in this build: THIS ONE account cannot be
            // built, reported by its own id, exactly like an IMAP account with
            // no stored password. `attachStoredAccounts()` logs it and carries
            // on, so every Gmail/IMAP/Apple Mail account stays attached and the
            // plugin still loads — the "not configured" state is one dead
            // account row, never an app-wide failure.
            guard let graphAuth else {
                throw MailError.notAuthenticated(accountID: account.id)
            }
            return GraphProvider(accountID: account.id, auth: graphAuth)
        case .unsupported(let raw):
            throw MailError.unsupportedProvider(kind: raw, accountID: account.id)
        }
    }

    /// Rebuilds the read-only `AppleMailProvider` from the bookmark saved when
    /// the user picked their Mail folder.
    ///
    /// Security-scoped access must outlive this call — the provider reads the
    /// directory lazily for as long as the account stays attached — so it is
    /// started here and stopped in `signOut`. The started URL is RETAINED in
    /// `accessedDirectories` for exactly that reason: `startAccessing` can only
    /// be balanced by `stopAccessing(theSameURL)`, so a factory that starts
    /// access without keeping the URL has no way to ever stop it, and the grant
    /// to the user's Mail folder then lives until the process exits.
    ///
    /// Keying by account also makes a re-attach idempotent, which matters
    /// because `attachStoredAccounts()` re-runs `makeProvider` for EVERY
    /// account whenever credentials are saved. Without the guard each pass adds
    /// another unbalanced start for the same URL, and the kernel's per-URL
    /// consumption count then never returns to zero no matter how many times
    /// `signOut` stops it.
    private func makeAppleMailProvider(for account: MailAccount) throws -> MailProvider {
        let key = DocumentKeys.appleMailDirectory(accountID: account.id)
        guard let data = host.documents.data(forKey: key) else {
            throw MailError.unsupportedProvider(kind: account.provider.identifier,
                                                accountID: account.id)
        }
        do {
            let resolved = try MailDirectoryBookmark(data: data)
                .resolve(securityScoped: securityScopedBookmarks)
            if accessedDirectories[account.id] != resolved.url {
                stopAccessingDirectory(accountID: account.id)
                if MailDirectoryBookmark.startAccessing(resolved.url) {
                    accessedDirectories[account.id] = resolved.url
                }
            }
            return AppleMailProvider(accountID: account.id, directory: resolved.url)
        } catch {
            // A bookmark that no longer resolves (the folder moved or the
            // sandbox grant lapsed) is this ONE account failing to attach,
            // reported by id like any other unbuildable account.
            throw MailError.unsupportedProvider(kind: account.provider.identifier,
                                                accountID: account.id)
        }
    }

    /// Rebuilds an `IMAPProvider` from the server settings saved when the account
    /// was added, plus the app password held in `host.secrets`.
    ///
    /// The connection is established **lazily**, inside the closure the provider
    /// calls per operation, and not here: `makeProvider` is synchronous and is
    /// re-run for every account by `attachStoredAccounts()` on every credential
    /// change, so opening a socket here would connect to every IMAP server the user
    /// has just to render the Accounts list.
    ///
    /// The lease caches nothing on purpose either — see `IMAPProvider.acquire`. A
    /// cached session would have to answer "is this socket still alive", and the honest
    /// answer at this layer is a fresh connect; Task 14's IDLE work is where a
    /// long-lived session gets an owner that can tell. Note that caching and *closing*
    /// are separate questions: whatever Task 14 does about reuse, the lease's `release`
    /// is what returns the connection slot, and it runs after every operation.
    private func makeIMAPProvider(for account: MailAccount) throws -> MailProvider {
        guard let data = host.documents.data(forKey: DocumentKeys.imapSettings(accountID: account.id)),
              let settings = try? JSONDecoder().decode(IMAPAccountSettings.self, from: data),
              let credential = IMAPAppPasswordStore.credential(
                accountID: account.id, username: settings.username, secrets: host.secrets)
        else {
            // No settings row, or no stored password: this ONE account cannot be
            // built, reported by id like every other unbuildable account.
            throw MailError.unsupportedProvider(kind: account.provider.identifier,
                                                accountID: account.id)
        }
        let open = openIMAPSession
        let accountID = account.id
        return IMAPProvider(accountID: account.id, submit: smtpSubmit(settings: settings,
                                                                      credential: credential,
                                                                      sender: account.address)) {
            [weak self] in
            let working = try await open(settings, credential)
            await self?.recordMailboxDirectory(working.directory, accountID: accountID)
            // The release is bound to THIS session, so `withSession` cannot log out of
            // somebody else's, and every acquire here has exactly one.
            return IMAPSessionLease(working: working) {
                await IMAPProvider.closeSession(working)
            }
        }
    }

    /// Writes the mailbox list this session just `LIST`ed over the persisted one.
    ///
    /// **This is what keeps the vocabulary and the move destination from
    /// disagreeing**, and the failure it prevents is losing mail into the wrong
    /// folder rather than a stale-looking list. `IMAPProvider.applyLabels` resolves
    /// its move *destination* from the live `working.directory`, while
    /// `LabelVocabularyResolver` renders the mutation from the *persisted* one. If
    /// the persisted copy predates a Trash folder the user has since created,
    /// `IMAPVocabulary.label(for: .trash)` answers `nil`, `render` drops it,
    /// `ThreadAction.trash` arrives as a bare `remove: ["INBOX"]` — which is
    /// byte-identical to an archive — and the message is moved to **Archive instead
    /// of Trash**, with no error anywhere. Refreshing here means every operation
    /// after the first sees the mailboxes the server actually has.
    ///
    /// Written from the acquire, not from account setup alone, because that is the
    /// one place a fresh `LIST` already exists: `openSession` performs it once per
    /// session regardless, so this costs no round trip.
    ///
    /// **The residual window, stated rather than implied:** a folder created between
    /// the moment a mutation is rendered and the moment the session is acquired is
    /// still missed for that one action. Rendering happens upstream of the provider
    /// (`ThreadMutationApplier`, the outbox), so no write here can close that gap;
    /// what it closes is the unbounded one, where the persisted list was written
    /// once at account-add and never again.
    ///
    /// A second `DocumentMailStore` over the same `host.documents` rather than a
    /// reference to the runtime's: that type holds no cached state — a
    /// `PluginDocumentStore`, a coder pair, and a diagnostic key — so two instances
    /// read and write the same bytes, and this keeps the key name and the encoding
    /// in the one type that owns them instead of duplicating both here.
    private func recordMailboxDirectory(_ directory: IMAPMailboxDirectory,
                                        accountID: String) {
        // Best effort: a failed write must never fail the operation the session was
        // acquired for. The consequence of a miss is one more stale read, which is
        // the state this whole method is improving on, not a new failure mode.
        try? DocumentMailStore(documents: host.documents)
            .saveIMAPMailboxDirectory(directory, accountID: accountID)
    }

    /// How an IMAP session is established. The production value is
    /// `IMAPProvider.openSession`; a test substitutes a scripted one.
    ///
    /// Internal, like `securityScopedBookmarks`, and for the same reason: it is a
    /// seam, and a `public` one would let a caller outside this module redirect
    /// every IMAP connection this app makes. Both `makeProvider` and
    /// `testIMAPConnection` go through it, so a test exercises the same code path
    /// production does rather than a parallel one.
    var openIMAPSession: @Sendable (IMAPAccountSettings, IMAPCredential) async throws
        -> IMAPWorkingSession = { try await IMAPProvider.openSession(settings: $0,
                                                                     credential: $1) }

    /// How this account submits mail, or `nil` when no SMTP server is configured.
    ///
    /// Built here rather than inside `IMAPProvider` because this is the file that
    /// holds the credential path: the provider receives a closure it can call and
    /// never an `IMAPCredential`, so no part of the read/write path can reach the
    /// password even by accident.
    private func smtpSubmit(settings: IMAPAccountSettings, credential: IMAPCredential,
                            sender: String)
        -> (@Sendable (OutgoingMessage) async throws -> String)? {
        guard let endpoint = settings.smtpEndpoint else { return nil }
        let submitter = SMTPSubmitter(endpoint: endpoint, sender: sender,
                                      credential: credential)
        return { try await submitter.submit($0) }
    }

    // MARK: IMAP account setup

    /// A stable account id for an IMAP mailbox.
    ///
    /// Derived from the login rather than random, so re-adding the same mailbox
    /// **replaces** it instead of producing a second account row pointing at the
    /// same server — which would then be backfilled twice into two sets of shards.
    /// Lowercased because IMAP usernames and hostnames are compared
    /// case-insensitively by every server this targets.
    static func imapAccountID(settings: IMAPAccountSettings) -> String {
        "imap-\(settings.username.lowercased())@\(settings.host.lowercased())"
    }

    /// Persists one IMAP account's server settings and its app password, each to
    /// the store that is right for it.
    ///
    /// The split is the whole point and is asserted structurally by
    /// `IMAPAccountSetupTests`: `settings` (host, port, TLS mode, username) is a
    /// *location* and goes to `host.documents`; `password` is a credential and goes
    /// to `host.secrets` through `IMAPAppPasswordStore` and nowhere else. This
    /// function is the only place in the app that writes an IMAP app password.
    func saveIMAPAccount(settings: IMAPAccountSettings, password: String,
                         accountID: String) throws {
        host.documents.setData(try JSONEncoder().encode(settings),
                               forKey: DocumentKeys.imapSettings(accountID: accountID))
        IMAPAppPasswordStore.store(password, accountID: accountID, secrets: host.secrets)
    }

    /// Opens a session with the given settings and password *without* persisting
    /// either, and returns the mailboxes the server listed.
    ///
    /// Nothing is written before the server has accepted the credential, so a failed
    /// attempt leaves no account row, no settings document and no secret behind —
    /// there is no "half-added account" state to clean up.
    func probeIMAP(settings: IMAPAccountSettings, password: String) async
        -> Result<IMAPMailboxDirectory, IMAPAccountSetup.ConnectionFailure> {
        let credential = IMAPCredential.appPassword(username: settings.username,
                                                    password: password)
        do {
            let working = try await openIMAPSession(settings, credential)
            let directory = working.directory
            await IMAPProvider.closeSession(working)
            return .success(directory)
        } catch {
            return .failure(IMAPAccountSetup.classify(error))
        }
    }

    /// Records the folder an `.appleMail` account imports from, so the
    /// provider can be rebuilt on the next launch without re-prompting.
    public func saveAppleMailDirectory(_ bookmark: MailDirectoryBookmark, accountID: String) {
        host.documents.setData(bookmark.data,
                               forKey: DocumentKeys.appleMailDirectory(accountID: accountID))
    }

    // MARK: Sign-out

    /// Forgets every credential this factory holds for one account: the Gmail
    /// refresh token, the IMAP app password, and the Apple Mail directory
    /// bookmark. Scoped to ONE account — every other account's credentials stay
    /// untouched, matching `RavenRuntime.signOut`'s contract.
    ///
    /// The IMAP app password is cleared unconditionally rather than only for
    /// `.imap` accounts, because this function is given an id and not a kind, and
    /// clearing a key that was never written is a no-op. Making it conditional
    /// would mean an account whose row failed to decode — the exact case
    /// `ProviderKind.unsupported` exists for — keeps its password forever.
    ///
    /// The *documents* an IMAP account owns (`imap-settings-<id>`,
    /// `imap-mailboxes-<id>`) are removed by `DocumentMailStore.purge`, with every
    /// other per-account document, so a purge that does not run through here is
    /// still complete. This function owns only what lives in `host.secrets` plus
    /// the live security-scoped grant, which is the one thing a store cannot
    /// release.
    public func signOut(accountID: String) {
        gmailAuth?.signOut(accountID: accountID)
        // UNCONDITIONAL, via a static needing no instance — the whole point.
        // `graphAuth?.signOut(…)` alone looks equivalent and is not: `graphAuth`
        // is nil whenever this build has no Azure registration (every build
        // today) or the saved one was removed, and in exactly those cases the
        // optional chain does nothing and `graph-refresh-<id>` SURVIVES THE
        // SIGN-OUT in the Keychain. A credential outliving its revocation is
        // worse than either purge gap this branch has closed.
        // `IMAPAppPasswordStore.clear` below is a static for the same reason.
        // Clearing a never-written key is a no-op, and the two backends use
        // different keys, so this cannot clear Gmail's.
        GraphAuth.clearRefreshToken(accountID: accountID, secrets: host.secrets)
        // The live instance too, when there is one: only it holds the
        // in-memory access token, which the static cannot reach.
        graphAuth?.signOut(accountID: accountID)
        IMAPAppPasswordStore.clear(accountID: accountID, secrets: host.secrets)
        stopAccessingDirectory(accountID: accountID)
        host.documents.setData(nil, forKey: DocumentKeys.appleMailDirectory(accountID: accountID))
    }

    /// Relinquishes this account's security-scoped grant, if it holds one.
    /// Separate from `signOut` because `makeAppleMailProvider` also needs it,
    /// on the path where a bookmark now resolves to a DIFFERENT folder than the
    /// one currently being accessed — the old grant has to go or it leaks.
    private func stopAccessingDirectory(accountID: String) {
        guard let url = accessedDirectories.removeValue(forKey: accountID) else { return }
        MailDirectoryBookmark.stopAccessing(url)
    }

    /// The security-scoped URL currently being accessed per account, so that
    /// `startAccessing` can be balanced. Test-visible so a suite can assert the
    /// balance rather than infer it.
    var accessedDirectories: [String: URL] = [:]
}
