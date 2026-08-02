import Foundation
import CryptoKit
import AuthenticationServices
import AppKit
import AinkradAppKit

/// OAuth with PKCE against a Desktop client, over a loopback redirect. The
/// refresh token goes to the host's Keychain-backed secret store; the access
/// token is held in memory only and never persisted.
@MainActor public final class GmailAuth: NSObject {
    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    private let secrets: PluginSecretStore
    private let clientID: String
    /// Test-only seam: when set, `accessToken(accountID:)` calls this instead
    /// of performing the real network refresh-token exchange. Left nil in
    /// production, where the real HTTP exchange in `exchange(parameters:)`
    /// runs. This is the only refactor made beyond the brief's Step 3 code,
    /// and it does not change the public `accessToken(accountID:)` signature
    /// that `GmailProvider` depends on.
    private let refreshExchangeOverride: (@MainActor (String) async throws -> (String, TimeInterval))?
    // Not `private` so `@testable import` tests can seed a cached token
    // directly, without needing a real network round trip or a browser flow.
    var accessTokens: [String: (token: String, expiry: Date)] = [:]
    private var session: ASWebAuthenticationSession?

    public init(secrets: PluginSecretStore, clientID: String,
                refreshExchange: (@MainActor (String) async throws -> (String, TimeInterval))? = nil) {
        self.secrets = secrets
        self.clientID = clientID
        self.refreshExchangeOverride = refreshExchange
    }

    // MARK: PKCE

    public static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    public static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func authorizationURL(clientID: String, redirectURI: String,
                                        verifier: String) -> URL {
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
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
        }
        accessTokens[accountID] = (token, Date().addingTimeInterval(lifetime))
        return token
    }

    /// Runs the browser flow and stores the refresh token. Returns the address.
    public func authorize(redirectPort: Int = 7654) async throws -> (accountID: String, address: String) {
        let verifier = Self.codeVerifier()
        let redirectURI = "http://127.0.0.1:\(redirectPort)"
        let code = try await presentBrowserFlow(
            url: Self.authorizationURL(clientID: clientID, redirectURI: redirectURI,
                                       verifier: verifier),
            redirectURI: redirectURI)
        let payload = try await exchangeFull(parameters: [
            "client_id": clientID,
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

    private func exchangeFull(parameters: [String: String]) async throws -> TokenPayload {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

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

    private func presentBrowserFlow(url: URL, redirectURI: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: nil
            ) { callback, error in
                if let error {
                    continuation.resume(throwing: error); return
                }
                guard let callback,
                      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                      let code = items.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: MailError.decodingFailed("authorization callback"))
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }
}

extension GmailAuth: ASWebAuthenticationPresentationContextProviding {
    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.keyWindow ?? NSWindow() }
    }
}
