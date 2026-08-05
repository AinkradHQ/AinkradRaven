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

    /// Not a credential — the OAuth client id is only ever a lookup key
    /// against Google, and the user needs to see what they typed to fix a
    /// typo. Persisted as a document, unlike the secret below.
    static let clientIDKey = "gmail-client-id"
    /// The client secret IS a credential (see `GmailAuth`'s own documentation
    /// of the same point). Read from and written to `host.secrets` ONLY.
    static let clientSecretKey = "gmail-client-secret"

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

    // MARK: Credentials

    /// Whether a Gmail OAuth client exists, i.e. whether `authorize(kind:
    /// .gmail)` could possibly succeed.
    public var hasGmailCredentials: Bool { gmailAuth != nil }

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
    /// Only `.gmail` has an interactive flow today. `.imap` (Task 16) and
    /// `.graph` (Task 20) get theirs when their backends land, and
    /// `.appleMail` has none by nature: an imported local mailbox is chosen
    /// with a directory picker, not authorized, so it is added via
    /// `MailAccount` + `saveAppleMailDirectory` rather than through here.
    public func authorize(kind: MailAccount.ProviderKind,
                          onAuthorizationURL: (@Sendable (URL) -> Void)? = nil)
        async throws -> (accountID: String, address: String) {
        switch kind {
        case .gmail:
            guard let gmailAuth else { throw MailError.notAuthenticated(accountID: "") }
            return try await gmailAuth.authorize(onAuthorizationURL: onAuthorizationURL)
        case .imap, .graph, .appleMail, .unsupported:
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
            // The backend itself is a later task. Refusing by name here (rather
            // than being absent from the switch) is what lets an `accounts`
            // document that already names it load.
            throw MailError.unsupportedProvider(kind: account.provider.identifier,
                                                accountID: account.id)
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
        return IMAPProvider(accountID: account.id) {
            let working = try await IMAPProvider.openSession(settings: settings,
                                                             credential: credential)
            // The release is bound to THIS session, so `withSession` cannot log out of
            // somebody else's, and every acquire here has exactly one.
            return IMAPSessionLease(working: working) {
                await IMAPProvider.closeSession(working)
            }
        }
    }

    /// Records the folder an `.appleMail` account imports from, so the
    /// provider can be rebuilt on the next launch without re-prompting.
    public func saveAppleMailDirectory(_ bookmark: MailDirectoryBookmark, accountID: String) {
        host.documents.setData(bookmark.data,
                               forKey: DocumentKeys.appleMailDirectory(accountID: accountID))
    }

    // MARK: Sign-out

    /// Forgets everything this factory holds for one account: the Gmail
    /// refresh token and the Apple Mail directory bookmark. Scoped to ONE
    /// account — every other account's credentials stay untouched, matching
    /// `RavenRuntime.signOut`'s contract.
    public func signOut(accountID: String) {
        gmailAuth?.signOut(accountID: accountID)
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
