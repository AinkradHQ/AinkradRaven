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
    /// the address. Never exercised in tests against real Google traffic —
    /// see the task report.
    public func authorize() async throws -> (accountID: String, address: String) {
        let verifier = Self.codeVerifier()
        let state = Self.randomState()
        let (code, redirectURI) = try await LoopbackCallbackListener.run(
            timeout: Self.authorizationTimeout,
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
}

// MARK: - Loopback callback capture

/// Parses the OAuth redirect off the first line of a raw HTTP request, e.g.
/// `GET /?code=abc&state=xyz HTTP/1.1`. Pure and free of any networking, so
/// it is unit-testable without a socket.
enum CallbackRequestParser {
    struct Result: Equatable {
        let code: String?
        let error: String?
        let state: String?
    }

    static func parse(requestLine: String) -> Result {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET" else {
            return Result(code: nil, error: nil, state: nil)
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            return Result(code: nil, error: nil, state: nil)
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return Result(code: value("code"), error: value("error"), state: value("state"))
    }

    /// The first line of a raw HTTP request, however the line ending was sent.
    static func firstLine(of rawRequest: String) -> String? {
        rawRequest.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }).first.map(String.init)
    }
}

/// Binds a one-shot loopback HTTP listener on an OS-chosen port, opens the
/// authorization URL in the browser once the port is known, and resolves with
/// the `code` from the first request the listener receives — tearing itself
/// down exactly once on every path (success, denial, malformed request, or
/// timeout).
///
/// This type has never been exercised against real Google traffic — see the
/// task report. Its socket-handling is deliberately not unit-tested (that
/// would require real networking); the parsing it depends on
/// (`CallbackRequestParser`) is pure and is tested directly instead.
enum LoopbackCallbackListener {
    enum ListenerError: Error, Equatable {
        case portUnavailable
        case authorizationDenied(String)
        case malformedCallback
        case stateMismatch
        case timedOut
    }

    /// - Parameters:
    ///   - openBrowser: called once the listener is bound, with the actual
    ///     port; must return the `redirect_uri` used, so the caller can reuse
    ///     it for the token exchange.
    static func run(
        timeout: Duration,
        openBrowser: @escaping @Sendable (UInt16) -> String,
        expectedState: String
    ) async throws -> (code: String, redirectURI: String) {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = Coordinator(expectedState: expectedState,
                                           openBrowser: openBrowser,
                                           continuation: continuation)
            coordinator.start(timeout: timeout)
        }
    }

    /// All mutable state and callback wiring for one authorization attempt.
    /// Every `NWListener`/`NWConnection` callback used here runs on
    /// `queue: .main`, and the timeout is scheduled on that same queue via
    /// `DispatchQueue.main.asyncAfter` (not an unstructured `Task`, which
    /// would run on the concurrent executor and race the queue-confined
    /// callbacks) — so all mutable state on this type really is touched from
    /// one queue only, and `@unchecked Sendable` describes a mechanism that
    /// is actually true rather than an assumption. The exactly-once resume
    /// guarantee itself does not depend on that queue confinement, though:
    /// it is delegated to `OneShotResumeGuard`, which is independently lock-
    /// protected and safe even if called from genuinely concurrent contexts.
    private final class Coordinator: @unchecked Sendable {
        private let expectedState: String
        private let openBrowser: @Sendable (UInt16) -> String
        private let resumeGuard: OneShotResumeGuard<Result<(code: String, redirectURI: String), Error>>
        private var listener: NWListener?
        private var redirectURI = ""
        private var timeoutWorkItem: DispatchWorkItem?

        init(expectedState: String,
             openBrowser: @escaping @Sendable (UInt16) -> String,
             continuation: CheckedContinuation<(code: String, redirectURI: String), Error>) {
            self.expectedState = expectedState
            self.openBrowser = openBrowser
            self.resumeGuard = OneShotResumeGuard { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }

        func start(timeout: Duration) {
            // The redirect is `http://localhost:PORT`, and "localhost" can
            // resolve to either the IPv4 loop (127.0.0.1) or the IPv6 loop
            // (::1) depending on the browser/OS resolver order — so the
            // listener must accept on both families, not just IPv4, or a
            // browser that resolves to ::1 will hit a closed port and the
            // flow will hang forever.
            //
            // `acceptLocalOnly` is what makes that safe: rather than binding
            // to the IPv4/IPv6 wildcard (which would accept connections from
            // *any* interface, not just loopback), it binds wide but tells
            // the OS to only hand back connections whose *peer* is the local
            // machine itself. That is what actually guarantees both
            // properties at once — loopback-only, and family-agnostic —
            // rather than requiring a second listener bound to a second
            // address family.
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            guard let listener = try? NWListener(using: parameters, on: .any) else {
                finish(.failure(ListenerError.portUnavailable))
                return
            }
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.start(queue: .main)

            // Scheduled on the same queue as every Network callback above, so
            // the timeout can never race a connection callback that is
            // concurrently deciding whether to finish. `finish(_:)` cancels
            // this work item on every other exit path.
            let workItem = DispatchWorkItem { [weak self] in
                self?.finish(.failure(ListenerError.timedOut))
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout.timeInterval, execute: workItem)
        }

        private func handleListenerState(_ state: NWListener.State) {
            switch state {
            case .ready:
                guard let port = listener?.port else {
                    finish(.failure(ListenerError.portUnavailable))
                    return
                }
                redirectURI = openBrowser(port.rawValue)
            case .failed:
                finish(.failure(ListenerError.portUnavailable))
            case .waiting:
                // NWListener retries a `.waiting` state (e.g. transient bind
                // contention) on its own, but leaving it unhandled meant the
                // only way out of a genuinely stuck bind was the full
                // authorization timeout. Fail fast instead: a loopback bind
                // that cannot become ready promptly is not worth making the
                // user sit through several minutes of "please wait".
                finish(.failure(ListenerError.portUnavailable))
            default:
                break
            }
        }

        private func handle(_ connection: NWConnection) {
            connection.stateUpdateHandler = { state in
                if case .failed = state { connection.cancel() }
            }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
                defer { connection.cancel() }
                guard let self else { return }
                if error != nil {
                    self.finish(.failure(ListenerError.malformedCallback))
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8),
                      let line = CallbackRequestParser.firstLine(of: text) else {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.malformedCallback))
                    return
                }
                let callback = CallbackRequestParser.parse(requestLine: line)
                if let oauthError = callback.error {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.authorizationDenied(oauthError)))
                    return
                }
                guard let code = callback.code else {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.malformedCallback))
                    return
                }
                guard callback.state == self.expectedState else {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.stateMismatch))
                    return
                }
                Self.respond(connection, success: true)
                self.finish(.success(code))
            }
        }

        private func finish(_ result: Result<String, Error>) {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            listener?.cancel()
            switch result {
            case .success(let code): resumeGuard.fire(.success((code, redirectURI)))
            case .failure(let error): resumeGuard.fire(.failure(error))
            }
        }

        private static func respond(_ connection: NWConnection, success: Bool) {
            let title = success ? "Signed in" : "Sign-in failed"
            let body = success
                ? "You can close this tab and return to Mail."
                : "Something went wrong. You can close this tab and try again."
            let html = "<html><body><h2>\(title)</h2><p>\(body)</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// Guarantees a completion closure fires at most once, even under genuinely
/// concurrent invocation from multiple threads — independent of any queue or
/// actor confinement its caller may or may not have. Backed by a lock rather
/// than by "everything happens to run on the same queue," so the exactly-
/// once property holds regardless of how callers are scheduled. Stress-tested
/// in `GmailAuthTests.swift` by firing from many concurrent tasks and
/// asserting the completion runs exactly once.
final class OneShotResumeGuard<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private let onFirstFire: (T) -> Void

    init(onFirstFire: @escaping (T) -> Void) {
        self.onFirstFire = onFirstFire
    }

    /// Fires `onFirstFire` with `value` if (and only if) this is the first
    /// call. Returns whether this call was the one that fired.
    @discardableResult
    func fire(_ value: T) -> Bool {
        lock.lock()
        let shouldFire = !hasFired
        if shouldFire { hasFired = true }
        lock.unlock()
        if shouldFire { onFirstFire(value) }
        return shouldFire
    }
}
