import Foundation
import AppKit
import AinkradAppKit

/// Gmail's OAuth configuration, on top of the provider-neutral `Auth/` layer.
///
/// What is left here is only what is genuinely Google's: the endpoints, the
/// scopes, the `access_type=offline` + `prompt=consent` pair, the loopback
/// redirect host, and the userinfo address lookup. The loopback listener
/// (`Auth/LoopbackCallbackListener.swift`), the PKCE helpers (`Auth/PKCE.swift`)
/// and the token exchanges (`Auth/OAuthTokenClient.swift`) are shared with every
/// other OAuth provider — there is one implementation of each, not one per
/// provider.
///
/// The refresh token goes to the host's Keychain-backed secret store; the access
/// token is held in memory only, in `accessTokens`, and never persisted. This
/// type holds no `PluginDocumentStore` and never has, so no token can reach
/// document storage from here.
///
/// Google's Desktop OAuth client type requires a loopback (`http://localhost`)
/// redirect — a custom URI scheme is not an option for this client type. That
/// redirect is captured by binding a minimal, one-shot `NWListener` on an
/// OS-chosen port *before* opening the authorization URL in the user's default
/// browser (`NSWorkspace`), rather than via `ASWebAuthenticationSession` (which
/// expects a universal-link callback and never intercepts a loopback HTTP
/// redirect).
@MainActor public final class GmailAuth {
    public nonisolated static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    private nonisolated static let authorizationEndpoint =
        URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private nonisolated static let tokenEndpoint =
        URL(string: "https://oauth2.googleapis.com/token")!
    private nonisolated static let userInfoEndpoint =
        URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

    /// `offline` + `consent` are what actually yield a refresh token; without
    /// both, a re-authorization returns only an access token and the account
    /// silently stops syncing an hour later. Google-specific, hence here rather
    /// than in `OAuthTokenClient`.
    private nonisolated static let offlineParameters = [
        "access_type": "offline",
        "prompt": "consent",
    ]

    /// How long the loopback listener stays up waiting for the user to finish
    /// the consent screen before it tears itself down.
    private static let authorizationTimeout: Duration = .seconds(180)

    private let secrets: PluginSecretStore
    private let tokens: OAuthTokenClient
    private let session: URLSession
    /// Test-only seam: when set, `accessToken(accountID:)` calls this instead
    /// of performing the real network refresh-token exchange. Left nil in
    /// production, where the real HTTP exchange in `OAuthTokenClient` runs.
    /// This does not change the public `accessToken(accountID:)` signature that
    /// `GmailProvider` depends on.
    private let refreshExchangeOverride: (@MainActor (String) async throws -> (String, TimeInterval))?
    // Not `private` so `@testable import` tests can seed a cached token
    // directly, without needing a real network round trip or a browser flow.
    var accessTokens: [String: (token: String, expiry: Date)] = [:]

    /// - Parameter clientSecret: the Desktop OAuth client's secret. Google's
    ///   token endpoint requires it for BOTH the authorization-code exchange and
    ///   every refresh-token exchange — omitting it (as this file did before)
    ///   makes every exchange fail with `invalid_client`. Both halves of that
    ///   rule now live in `OAuthTokenClient`, which documents the invariant in
    ///   full on `OAuthConfiguration.clientSecret`.
    ///
    ///   Design decision, unchanged by the extraction: this is taken as a plain
    ///   constructor argument, exactly like `clientID`, rather than being handed
    ///   the `secrets` store plus a key name and reaching in for it. That keeps
    ///   the *only* sanctioned origin of this value outside this type entirely.
    ///   The caller must already hold the secret (typically having just read it
    ///   from `host.secrets`, or parsed it at process startup from the OAuth
    ///   client JSON) and hands it over as a bare value; neither this type nor
    ///   `OAuthTokenClient` ever calls `secrets.secret(forKey:)` or
    ///   `secrets.setSecret(forKey:)` for it, and neither writes it anywhere —
    ///   only the refresh token obtained below gets persisted, into `secrets`,
    ///   unchanged from before. Consequently there is no key name, no document
    ///   path, and no code on this path that could ever be misdirected at
    ///   `PluginDocumentStore` — the only way this leaks is if code *outside*
    ///   these two files chooses to persist it somewhere it shouldn't, which is
    ///   a mistake this design cannot make on its own.
    ///
    ///   Never logged, never interpolated into a `MailError`, never printed.
    /// - Parameter session: injectable so tests can drive the token and userinfo
    ///   requests through a stubbed protocol. Defaults to `.shared`.
    public init(secrets: PluginSecretStore, clientID: String, clientSecret: String,
                session: URLSession = .shared,
                refreshExchange: (@MainActor (String) async throws -> (String, TimeInterval))? = nil) {
        self.secrets = secrets
        self.session = session
        self.tokens = OAuthTokenClient(
            configuration: OAuthConfiguration(authorizationEndpoint: Self.authorizationEndpoint,
                                              tokenEndpoint: Self.tokenEndpoint,
                                              clientID: clientID,
                                              clientSecret: clientSecret,
                                              scopes: Self.scopes),
            session: session)
        self.refreshExchangeOverride = refreshExchange
    }

    /// Gmail's authorization URL: the shared builder plus Google's offline-access
    /// parameters. Kept as a `static` so it can be built (and asserted on)
    /// without a `GmailAuth` instance.
    public nonisolated static func authorizationURL(clientID: String, redirectURI: String,
                                                    verifier: String, state: String) -> URL {
        let client = OAuthTokenClient(configuration: OAuthConfiguration(
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            // Not needed to build an authorization URL, and deliberately not
            // accepted here: the secret is never a query parameter.
            clientSecret: nil,
            scopes: scopes))
        return client.authorizationURL(redirectURI: redirectURI, verifier: verifier,
                                       state: state,
                                       additionalParameters: offlineParameters)
    }

    // MARK: Token exchange

    /// Returns a valid access token, refreshing when the cached one is stale.
    public func accessToken(accountID: String) async throws -> String {
        if let cached = accessTokens[accountID], cached.expiry > Date().addingTimeInterval(60) {
            return cached.token
        }
        guard let refresh = secrets.secret(forKey: "refresh-\(accountID)") else {
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

    /// Runs the loopback browser flow and stores the refresh token. Returns
    /// the address.
    ///
    /// - Parameter onAuthorizationURL: called once, with the fully-built
    ///   authorization URL, immediately BEFORE `NSWorkspace.shared.open` is
    ///   asked to launch it. `NSWorkspace.shared.open` is not guaranteed to
    ///   reliably surface a browser from every kind of host process (observed
    ///   in practice from a bare command-line tool with no app bundle — see
    ///   `RavenDevAuth`), so this exists as the fallback: whoever is driving
    ///   the flow can present or log the URL for the human to open by hand if
    ///   no browser window appears. Defaulted to `nil` so every existing call
    ///   site remains source-compatible. The URL itself is safe to surface
    ///   anywhere (print it, log it, show it in UI) — it carries only the
    ///   client id, requested scopes, `state`, and the PKCE challenge, none of
    ///   which are secrets.
    /// - Parameter timeout: how long the loopback listener waits for the
    ///   browser callback. Defaults to `authorizationTimeout`; exposed so a
    ///   dev harness can ask for a deliberately short wait and observe the
    ///   whole bind-and-open path terminate with a definite `timedOut` error,
    ///   without a human having to sit through the consent screen.
    public func authorize(timeout: Duration? = nil,
                          onAuthorizationURL: (@Sendable (URL) -> Void)? = nil) async throws
        -> (accountID: String, address: String) {
        let verifier = PKCE.codeVerifier()
        let state = PKCE.randomState()
        let clientID = tokens.configuration.clientID
        let (code, redirectURI) = try await LoopbackCallbackListener.run(
            timeout: timeout ?? Self.authorizationTimeout,
            openBrowser: { port in
                // Must be "localhost", not "127.0.0.1": the registered Desktop
                // client's redirect URI is `http://localhost` (Google matches
                // loopback redirects by host and ignores the port for
                // installed apps), and a 127.0.0.1 URI can be rejected against
                // that registration. See `LoopbackCallbackListener` for how
                // the listener still guarantees it receives this regardless
                // of whether "localhost" resolves to the IPv4 or IPv6 loop.
                let redirectURI = "http://localhost:\(port)"
                let url = Self.authorizationURL(clientID: clientID, redirectURI: redirectURI,
                                                 verifier: verifier, state: state)
                onAuthorizationURL?(url)
                NSWorkspace.shared.open(url)
                return redirectURI
            },
            expectedState: state)

        return try await completeAuthorization(code: code, verifier: verifier,
                                               redirectURI: redirectURI)
    }

    /// The half of `authorize` that runs after the browser callback: the
    /// authorization-code exchange, the address lookup, and persisting the
    /// refresh token. Split out (internal, not public) so a test can drive the
    /// exact production code path over a stubbed `URLSession` — the browser and
    /// the loopback socket are the only untestable parts, and they are not in
    /// here.
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
            secrets.setSecret(refresh, forKey: "refresh-\(accountID)")
        }
        // The access token's ONLY destination: memory, for this process.
        accessTokens[accountID] = (payload.accessToken,
                                   Date().addingTimeInterval(payload.expiresIn))
        return (accountID, address)
    }

    public func signOut(accountID: String) {
        secrets.setSecret(nil, forKey: "refresh-\(accountID)")
        accessTokens.removeValue(forKey: accountID)
    }

    // MARK: Plumbing

    private func fetchAddress(accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        struct Wire: Decodable { let email: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw MailError.decodingFailed("userinfo")
        }
        return wire.email
    }
}
