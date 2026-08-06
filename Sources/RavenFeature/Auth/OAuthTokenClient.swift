import Foundation

/// The endpoint-and-identity half of an OAuth 2.0 authorization-code + PKCE
/// flow, as plain input. Everything provider-specific about a flow lives in a
/// value of this type; nothing in `Auth/` hardcodes a provider.
public struct OAuthConfiguration: Sendable {
    /// Where the browser is sent (`response_type=code`).
    public let authorizationEndpoint: URL
    /// Where the code and the refresh token are exchanged.
    public let tokenEndpoint: URL
    public let clientID: String
    /// The registered client's secret, when the client type has one.
    ///
    /// **Both exchanges.** For an installed-app/Desktop client type, the token
    /// endpoint requires this on the authorization-code exchange *and* on every
    /// refresh-token exchange — omitting it on either one makes that exchange
    /// fail with `invalid_client`, which is a failure mode that only shows up
    /// against a live server (an hour later, when the first refresh is due) and
    /// never in a test. `authorizationCode(...)` and `refresh(...)` below both
    /// add it, and that symmetry is load-bearing.
    ///
    /// Optional because a public client (no secret issued) is a legitimate
    /// configuration: `nil` omits the parameter entirely rather than sending an
    /// empty one.
    ///
    /// **This value is a credential.** It is never logged, never printed, never
    /// interpolated into a `MailError`, and never written to a document. The
    /// design that makes that structurally true rather than merely observed:
    /// this type takes the secret as a plain stored value handed over by the
    /// caller, which must already hold it (typically having parsed it at
    /// startup from the OAuth client JSON, or read it from `host.secrets`).
    /// This type never calls `PluginSecretStore.secret(forKey:)` or
    /// `setSecret(forKey:)` for it and knows no key name for it, and it holds
    /// no reference to a `PluginDocumentStore` at all — so there is no code
    /// path inside `Auth/` that could be misdirected at document storage. The
    /// only value this layer ever persists is the refresh token, and that is
    /// persisted by the *caller* (the provider's auth type) into `host.secrets`
    /// — the only persistence anywhere on this path. The only
    /// way the secret leaks is if code outside this layer chooses to persist it
    /// somewhere it shouldn't, which is a mistake this design cannot make on
    /// its own.
    public let clientSecret: String?
    public let scopes: [String]

    public init(authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String,
                clientSecret: String?, scopes: [String]) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }
}

/// One token-endpoint implementation for every provider Raven signs into.
///
/// Extracted from the provider-specific auth type that had the endpoints, the
/// form encoding and the wire decoding welded to one provider. The behaviour
/// here is unchanged from that version — including the client-secret-on-both-exchanges rule
/// documented on `OAuthConfiguration.clientSecret`.
///
/// Holds no `PluginDocumentStore` and no `PluginSecretStore`: tokens are
/// returned to the caller as values and this type persists nothing. Access
/// tokens therefore cannot outlive the caller's memory unless the caller stores
/// them, and refresh tokens reach the Keychain-backed secret store only because
/// the caller puts them there.
public struct OAuthTokenClient: Sendable {
    /// What a token endpoint hands back. `refreshToken` is absent on a refresh
    /// exchange (and on an authorization-code exchange that did not request
    /// offline access).
    public struct TokenPayload: Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: TimeInterval
    }

    public let configuration: OAuthConfiguration
    private let session: URLSession

    /// - Parameter session: injectable so tests can drive the exchanges through
    ///   a stubbed protocol instead of the live network. Defaults to `.shared`,
    ///   which is what production uses.
    public init(configuration: OAuthConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: Authorization URL

    /// Builds the `response_type=code` URL to open in the browser.
    ///
    /// The URL itself is safe to surface anywhere (print it, log it, show it in
    /// UI) — it carries only the client id, the requested scopes, `state`, and
    /// the PKCE challenge, none of which are secrets. In particular the client
    /// *secret* is never a query parameter here.
    ///
    /// - Parameter additionalParameters: provider-specific extras (e.g. the
    ///   offline-access and consent-prompt pair one provider needs to actually
    ///   issue a refresh token). Applied last, so a provider can also override
    ///   a default.
    public func authorizationURL(redirectURI: String, verifier: String, state: String,
                                 additionalParameters: [String: String] = [:]) -> URL {
        var components = URLComponents(url: configuration.authorizationEndpoint,
                                       resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: PKCE.codeChallenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        for (name, value) in additionalParameters.sorted(by: { $0.key < $1.key }) {
            items.removeAll { $0.name == name }
            items.append(.init(name: name, value: value))
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: Exchanges

    /// The authorization-code exchange. Sends the client secret when the
    /// configuration has one — see `OAuthConfiguration.clientSecret`.
    public func authorizationCode(_ code: String, verifier: String,
                                  redirectURI: String) async throws -> TokenPayload {
        var parameters = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let secret = configuration.clientSecret { parameters["client_secret"] = secret }
        return try await exchange(parameters: parameters)
    }

    /// The refresh-token exchange. Sends the client secret when the
    /// configuration has one — the *same* rule as the code exchange, and the
    /// half that was originally missing.
    public func refresh(refreshToken: String) async throws -> TokenPayload {
        var parameters = [
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = configuration.clientSecret { parameters["client_secret"] = secret }
        return try await exchange(parameters: parameters)
    }

    // MARK: Plumbing

    /// RFC 3986 unreserved characters — exactly what
    /// `application/x-www-form-urlencoded` must leave unescaped. The previous
    /// encoding used `.alphanumerics`, which under-escapes: it left `+`, `/`,
    /// `=`, `&`, and space in values completely unescaped, so any such value
    /// (a refresh token or auth code containing one of those bytes) would
    /// corrupt the parameter boundaries when the token endpoint parsed the body
    /// back. This has not bitten in practice only because every parameter value
    /// used so far happened to be URL-safe.
    static func formURLEncode(_ parameters: [String: String]) -> Data {
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

    private func exchange(parameters: [String: String]) async throws -> TokenPayload {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncode(parameters)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // The response body is the provider's error document; the request
            // body (which carries the client secret) is deliberately NOT part
            // of this error.
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
}
