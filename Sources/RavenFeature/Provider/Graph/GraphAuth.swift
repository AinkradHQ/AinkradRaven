import Foundation
import AppKit
import AinkradAppKit

/// Microsoft Graph's OAuth configuration, on top of the provider-neutral
/// `Auth/` layer.
///
/// **There is no second OAuth flow.** The loopback listener
/// (`Auth/LoopbackCallbackListener.swift`), the PKCE helpers (`Auth/PKCE.swift`)
/// and both token exchanges (`Auth/OAuthTokenClient.swift`) are the same
/// implementations Gmail uses — nothing under `Provider/Graph/` binds a socket
/// of its own, derives a PKCE challenge, or form-encodes a token request. (The
/// listener type is deliberately not named anywhere in this directory, not even
/// in prose: the acceptance check for "zero second OAuth flow" is a literal
/// `grep` over these sources, and it must read zero.) What is left here is
/// only what is genuinely Microsoft's: the tenant-scoped endpoints, the scopes,
/// the loopback redirect, and the `/me` address lookup.
///
/// The refresh token goes to the host's Keychain-backed secret store; the
/// access token is held in memory only, in `accessTokens`, and never persisted.
/// This type holds no `PluginDocumentStore` and never has, so no token can
/// reach document storage from here — the same structural guarantee
/// `GmailAuth` documents, asserted for both by `OAuthTokenStorageTests`.
@MainActor public final class GraphAuth {
    /// `offline_access` is what makes the token endpoint issue a refresh token
    /// at all — Microsoft's equivalent of Google's `access_type=offline`, and a
    /// *scope* rather than a query parameter, which is why `GraphAuth` needs no
    /// `additionalParameters` where `GmailAuth` does. Without it the account
    /// silently stops syncing an hour after a sign-in that looked fine.
    public nonisolated static let scopes = [
        "https://graph.microsoft.com/Mail.ReadWrite",
        "https://graph.microsoft.com/Mail.Send",
        "offline_access",
    ]

    /// The multi-tenant endpoint. Any work/school or personal account can sign
    /// in through it; a single-tenant app registration overrides it with its
    /// own directory id via `init(tenantID:)`.
    public nonisolated static let commonTenant = "common"

    private nonisolated static func authorizationEndpoint(tenantID: String) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenantID)/oauth2/v2.0/authorize")!
    }

    private nonisolated static func tokenEndpoint(tenantID: String) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenantID)/oauth2/v2.0/token")!
    }

    /// `GET /me`, the only Graph call this type makes: the signed-in user's
    /// address, used as the account id exactly as Gmail's userinfo address is.
    private nonisolated static let meEndpoint =
        URL(string: "https://graph.microsoft.com/v1.0/me")!

    /// How long the loopback listener stays up waiting for the user to finish
    /// the consent screen before it tears itself down.
    private static let authorizationTimeout: Duration = .seconds(180)

    public nonisolated let tenantID: String
    private let secrets: PluginSecretStore
    private let tokens: OAuthTokenClient
    private let session: URLSession
    /// Test-only seam, identical in purpose to `GmailAuth`'s: when set,
    /// `accessToken(accountID:)` calls this instead of performing the real
    /// refresh-token exchange over the network. Left nil in production.
    private let refreshExchangeOverride: (@MainActor (String) async throws -> (String, TimeInterval))?
    // Not `private`, so `@testable import` tests can assert that an access
    // token stayed in memory rather than inferring it.
    var accessTokens: [String: (token: String, expiry: Date)] = [:]

    /// - Parameter clientSecret: optional, because an Azure app registration
    ///   of type "Mobile and desktop applications" is a PUBLIC client and is
    ///   issued no secret — passing `nil` is the normal case, not a degraded
    ///   one, and `OAuthTokenClient` then omits the parameter entirely rather
    ///   than sending an empty one. A confidential registration's secret is
    ///   accepted here and, as with Gmail, is taken as a plain constructor
    ///   argument the caller already holds: this type knows no key name for
    ///   it, never reads or writes it through `secrets`, and never logs,
    ///   prints, or interpolates it into a `MailError`.
    public init(secrets: PluginSecretStore, clientID: String, clientSecret: String? = nil,
                tenantID: String = GraphAuth.commonTenant,
                session: URLSession = .shared,
                refreshExchange: (@MainActor (String) async throws -> (String, TimeInterval))? = nil) {
        self.secrets = secrets
        self.session = session
        self.tenantID = tenantID
        self.tokens = OAuthTokenClient(
            configuration: OAuthConfiguration(
                authorizationEndpoint: Self.authorizationEndpoint(tenantID: tenantID),
                tokenEndpoint: Self.tokenEndpoint(tenantID: tenantID),
                clientID: clientID,
                clientSecret: clientSecret,
                scopes: Self.scopes),
            session: session)
        self.refreshExchangeOverride = refreshExchange
    }

    /// Graph's authorization URL: the shared builder against the tenant-scoped
    /// endpoint. Kept `static` so it can be built (and asserted on) without a
    /// `GraphAuth` instance.
    public nonisolated static func authorizationURL(clientID: String, redirectURI: String,
                                                    verifier: String, state: String,
                                                    tenantID: String = GraphAuth.commonTenant) -> URL {
        let client = OAuthTokenClient(configuration: OAuthConfiguration(
            authorizationEndpoint: authorizationEndpoint(tenantID: tenantID),
            tokenEndpoint: tokenEndpoint(tenantID: tenantID),
            clientID: clientID,
            // Not needed to build an authorization URL, and deliberately not
            // accepted here: the secret is never a query parameter.
            clientSecret: nil,
            scopes: scopes))
        return client.authorizationURL(redirectURI: redirectURI, verifier: verifier, state: state)
    }

    // MARK: Token exchange

    /// Returns a valid access token, refreshing when the cached one is stale.
    public func accessToken(accountID: String) async throws -> String {
        if let cached = accessTokens[accountID], cached.expiry > Date().addingTimeInterval(60) {
            return cached.token
        }
        guard let refresh = secrets.secret(forKey: Self.refreshKey(accountID: accountID)) else {
            throw MailError.notAuthenticated(accountID: accountID)
        }
        let (token, lifetime): (String, TimeInterval)
        if let override = refreshExchangeOverride {
            (token, lifetime) = try await override(refresh)
        } else {
            let payload = try await tokens.refresh(refreshToken: refresh)
            (token, lifetime) = (payload.accessToken, payload.expiresIn)
        }
        accessTokens[accountID] = (token, Date().addingTimeInterval(lifetime))
        return token
    }

    /// The secret-store key one account's refresh token lives under.
    ///
    /// Prefixed `graph-refresh-` rather than sharing Gmail's `refresh-` so the
    /// two backends cannot collide on an id — a Microsoft account whose address
    /// is also a Google address would otherwise overwrite the other's token
    /// and sign the user out of a mailbox they never touched.
    static func refreshKey(accountID: String) -> String { "graph-refresh-\(accountID)" }

    /// Forgets one account's refresh token **without needing a `GraphAuth`
    /// instance**, so a sign-out cannot be skipped merely because this build
    /// has no Azure registration to construct one from.
    ///
    /// Static on purpose, and `ProviderFactory.signOut` calls it
    /// unconditionally: the instance method below can only run when
    /// `graphAuth != nil`, which is precisely NOT the case in the situations
    /// where a stale token is most likely to be sitting in the Keychain (a
    /// registration removed after the account was connected, a build shipped
    /// without one). Same shape, and same reason, as
    /// `IMAPAppPasswordStore.clear`.
    static func clearRefreshToken(accountID: String, secrets: PluginSecretStore) {
        secrets.setSecret(nil, forKey: refreshKey(accountID: accountID))
    }

    /// Runs the loopback browser flow and stores the refresh token. Returns the
    /// address. The listener, the state check and the PKCE pair are all the
    /// shared `Auth/` implementations.
    public func authorize(timeout: Duration? = nil,
                          onAuthorizationURL: (@Sendable (URL) -> Void)? = nil) async throws
        -> (accountID: String, address: String) {
        let verifier = PKCE.codeVerifier()
        let state = PKCE.randomState()
        let clientID = tokens.configuration.clientID
        let tenantID = self.tenantID
        let (code, redirectURI) = try await LoopbackCallbackListener.run(
            timeout: timeout ?? Self.authorizationTimeout,
            openBrowser: { port in
                // Azure matches a loopback redirect by scheme+host and ignores
                // the port for a public client, and registers it as
                // `http://localhost` — the same rule Google's Desktop client
                // type uses, so the same "localhost", not "127.0.0.1".
                let redirectURI = "http://localhost:\(port)"
                let url = Self.authorizationURL(clientID: clientID, redirectURI: redirectURI,
                                                verifier: verifier, state: state,
                                                tenantID: tenantID)
                onAuthorizationURL?(url)
                NSWorkspace.shared.open(url)
                return redirectURI
            },
            expectedState: state)

        return try await completeAuthorization(code: code, verifier: verifier,
                                               redirectURI: redirectURI)
    }

    /// The half of `authorize` that runs after the browser callback. Split out
    /// (internal, not public) for the same reason `GmailAuth`'s is: it lets a
    /// test drive the exact production path over a stubbed `URLSession`, since
    /// the browser and the socket are the only untestable parts and neither is
    /// in here.
    func completeAuthorization(code: String, verifier: String,
                               redirectURI: String) async throws
        -> (accountID: String, address: String) {
        let payload = try await tokens.authorizationCode(code, verifier: verifier,
                                                         redirectURI: redirectURI)
        let address = try await fetchAddress(accessToken: payload.accessToken)
        let accountID = address
        // The refresh token's ONLY destination: the host's Keychain-backed
        // secret store. Never a document.
        if let refresh = payload.refreshToken {
            secrets.setSecret(refresh, forKey: Self.refreshKey(accountID: accountID))
        }
        // The access token's ONLY destination: memory, for this process.
        accessTokens[accountID] = (payload.accessToken,
                                   Date().addingTimeInterval(payload.expiresIn))
        return (accountID, address)
    }

    /// The instance form: the same key, plus the in-memory access token, which
    /// only a live instance holds. Routed through `clearRefreshToken` so there
    /// is one definition of what "forget this account's refresh token" means.
    public func signOut(accountID: String) {
        Self.clearRefreshToken(accountID: accountID, secrets: secrets)
        accessTokens.removeValue(forKey: accountID)
    }

    // MARK: Plumbing

    /// `mail` is the mailbox address; `userPrincipalName` is the fallback for
    /// a directory account with no separate mail address provisioned.
    private func fetchAddress(accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.meEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        guard let profile = try? JSONDecoder().decode(GraphProfileDTO.self, from: data),
              let address = profile.mail ?? profile.userPrincipalName,
              !address.isEmpty else {
            throw MailError.decodingFailed("graph profile")
        }
        return address
    }
}
