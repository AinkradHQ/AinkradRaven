import Foundation
import CryptoKit
import Network
import AppKit
import AinkradAppKit

/// OAuth with PKCE against a Desktop client, over a loopback redirect. The
/// refresh token goes to the host's Keychain-backed secret store; the access
/// token is held in memory only and never persisted.
///
/// Google's Desktop OAuth client type requires a loopback (`http://127.0.0.1`)
/// redirect — a custom URI scheme is not an option for this client type. That
/// redirect is captured by binding a minimal, one-shot `NWListener` on an
/// OS-chosen port *before* opening the authorization URL in the user's
/// default browser (`NSWorkspace`), rather than via
/// `ASWebAuthenticationSession` (which expects a universal-link callback and
/// never intercepts a loopback HTTP redirect).
@MainActor public final class GmailAuth {
    public nonisolated static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    /// How long the loopback listener stays up waiting for the user to finish
    /// the consent screen before it tears itself down.
    private static let authorizationTimeout: Duration = .seconds(180)

    private let secrets: PluginSecretStore
    private let clientID: String
    /// The Desktop OAuth client's secret. Google's token endpoint requires it
    /// for BOTH the authorization-code exchange and every refresh-token
    /// exchange — omitting it (as this file did before) makes every exchange
    /// fail with `invalid_client`.
    ///
    /// Design decision: `GmailAuth` takes this as a plain constructor
    /// argument, exactly like `clientID`, rather than being handed the
    /// `secrets` store plus a key name and reaching in for it itself. That is
    /// deliberate: it keeps the *only* sanctioned origin of this value outside
    /// this type entirely. The caller must already hold the secret (typically
    /// having just read it from `host.secrets`, or parsed it at process
    /// startup from the OAuth client JSON) and hands it over as a bare value;
    /// `GmailAuth` never calls `secrets.secret(forKey:)` or
    /// `secrets.setSecret(forKey:)` for it, and never writes it anywhere —
    /// only the refresh token it obtains gets persisted, into `secrets`,
    /// unchanged from before. Consequently there is no key name, no document
    /// path, and no code inside this type that could ever be misdirected at
    /// `PluginDocumentStore` — the only way this leaks is if code *outside*
    /// this file chooses to persist it somewhere it shouldn't, which is a
    /// mistake this design cannot make on its own.
    ///
    /// Never logged, never interpolated into a `MailError`, never printed.
    private let clientSecret: String
    /// Test-only seam: when set, `accessToken(accountID:)` calls this instead
    /// of performing the real network refresh-token exchange. Left nil in
    /// production, where the real HTTP exchange in `exchange(parameters:)`
    /// runs. This does not change the public `accessToken(accountID:)`
    /// signature that `GmailProvider` depends on.
    private let refreshExchangeOverride: (@MainActor (String) async throws -> (String, TimeInterval))?
    // Not `private` so `@testable import` tests can seed a cached token
    // directly, without needing a real network round trip or a browser flow.
    var accessTokens: [String: (token: String, expiry: Date)] = [:]

    public init(secrets: PluginSecretStore, clientID: String, clientSecret: String,
                refreshExchange: (@MainActor (String) async throws -> (String, TimeInterval))? = nil) {
        self.secrets = secrets
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshExchangeOverride = refreshExchange
    }

    // MARK: PKCE

    public nonisolated static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    public nonisolated static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A random, unguessable value for the `state` parameter. Reuses the same
    /// entropy source as `codeVerifier()` — both just need a long random
    /// base64url string.
    public nonisolated static func randomState() -> String { codeVerifier() }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public nonisolated static func authorizationURL(clientID: String, redirectURI: String,
                                        verifier: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            // offline + consent are what actually yield a refresh token; without
            // both, a re-authorization returns only an access token and the
            // account silently stops syncing an hour later.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: codeChallenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return components.url!
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
            (token, lifetime) = try await exchange(parameters: [
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
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
        let verifier = Self.codeVerifier()
        let state = Self.randomState()
        let (code, redirectURI) = try await LoopbackCallbackListener.run(
            timeout: timeout ?? Self.authorizationTimeout,
            openBrowser: { [clientID] port in
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

        let payload = try await exchangeFull(parameters: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        let address = try await fetchAddress(accessToken: payload.accessToken)
        let accountID = address
        if let refresh = payload.refreshToken {
            secrets.setSecret(refresh, forKey: "refresh-\(accountID)")
        }
        accessTokens[accountID] = (payload.accessToken,
                                   Date().addingTimeInterval(payload.expiresIn))
        return (accountID, address)
    }

    public func signOut(accountID: String) {
        secrets.setSecret(nil, forKey: "refresh-\(accountID)")
        accessTokens.removeValue(forKey: accountID)
    }

    // MARK: Plumbing

    private struct TokenPayload {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    private func exchange(parameters: [String: String]) async throws -> (String, TimeInterval) {
        let payload = try await exchangeFull(parameters: parameters)
        return (payload.accessToken, payload.expiresIn)
    }

    /// RFC 3986 unreserved characters — exactly what
    /// `application/x-www-form-urlencoded` must leave unescaped. The previous
    /// encoding used `.alphanumerics`, which under-escapes: it left `+`, `/`,
    /// `=`, `&`, and space in values completely unescaped, so any such value
    /// (a refresh token or auth code containing one of those bytes) would
    /// corrupt the parameter boundaries when Google's token endpoint parsed
    /// the body back. This has not bitten in practice only because every
    /// parameter value used so far happened to be URL-safe.
    nonisolated static func formURLEncode(_ parameters: [String: String]) -> Data {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        }
        let body = parameters
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func exchangeFull(parameters: [String: String]) async throws -> TokenPayload {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncode(parameters)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MailError.providerFailed(status: status,
                                           message: String(decoding: data, as: UTF8.self))
        }
        struct Wire: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw MailError.decodingFailed("token response")
        }
        return TokenPayload(accessToken: wire.access_token,
                            refreshToken: wire.refresh_token,
                            expiresIn: wire.expires_in)
    }

    private func fetchAddress(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Wire: Decodable { let email: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw MailError.decodingFailed("userinfo")
        }
        return wire.email
    }
}
