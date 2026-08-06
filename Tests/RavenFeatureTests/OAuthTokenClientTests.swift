import Testing
import Foundation
@testable import RavenFeature

/// Reads a request body whether `URLSession` left it on `httpBody` or handed
/// the protocol a stream (which is what actually happens inside a
/// `URLProtocol` subclass for a POST built with `httpBody`).
private func bodyString(of request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return String(decoding: data, as: UTF8.self)
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(url: String, body: String)] = []
    func record(_ request: URLRequest) {
        let entry = (request.url?.absoluteString ?? "", bodyString(of: request))
        lock.lock(); entries.append(entry); lock.unlock()
    }
    var all: [(url: String, body: String)] { lock.lock(); defer { lock.unlock() }; return entries }
}

private func makeConfiguration(clientSecret: String?) -> OAuthConfiguration {
    OAuthConfiguration(
        authorizationEndpoint: URL(string: "https://auth.example.test/authorize")!,
        tokenEndpoint: URL(string: "https://auth.example.test/token")!,
        clientID: "cid",
        clientSecret: clientSecret,
        scopes: ["scope.a", "scope.b"])
}

/// Moved out of `GmailAuthTests` (suite "Gmail auth form encoding") when the
/// token exchange was extracted. Assertions are unchanged; only the type they
/// address moved (`GmailAuth.formURLEncode` → `OAuthTokenClient.formURLEncode`).
///
/// Covers the fix to the exchange's form encoding (carry-over from Task
/// 12's review): `.alphanumerics` under-escaped reserved characters, which
/// had not bitten yet only because every parameter value used so far
/// happened to be URL-safe. `formURLEncode` is `static`, non-private, so
/// `@testable import` can exercise it directly without a network round trip.
@Suite("OAuth form encoding")
struct OAuthFormEncodingTests {
    @Test("a value containing +, /, =, & and a space is percent-escaped, not corrupted")
    func encodesReservedCharactersAndSpace() {
        let data = OAuthTokenClient.formURLEncode([
            "refresh_token": "a+b/c=d&e f",
        ])
        let body = String(decoding: data, as: UTF8.self)

        // The encoded body must round-trip back to the exact original value
        // when parsed as application/x-www-form-urlencoded — i.e. splitting
        // on the FIRST '&' the encoder itself introduced as a real separator
        // must not happen mid-value.
        #expect(body.hasPrefix("refresh_token="))
        let encodedValue = String(body.dropFirst("refresh_token=".count))
        // The raw value must not appear byte-for-byte (that's exactly the
        // under-escaping bug: '+', '/', '=', '&', and ' ' left untouched).
        #expect(encodedValue != "a+b/c=d&e f")
        #expect(encodedValue.contains("&") == false)  // no stray separator
        #expect(encodedValue.contains(" ") == false)   // no literal space

        // And it must decode back to exactly the original value.
        let recovered = encodedValue
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
        #expect(recovered == "a+b/c=d&e f")
    }

    @Test("plain alphanumeric values are encoded byte-identically (no regression for the common case)")
    func leavesSimpleValuesUnchanged() {
        let data = OAuthTokenClient.formURLEncode(["grant_type": "refresh_token"])
        #expect(String(decoding: data, as: UTF8.self) == "grant_type=refresh_token")
    }
}

@Suite("OAuth token client")
struct OAuthTokenClientTests {
    private static let tokenResponse = Data("""
    {"access_token":"at-1","refresh_token":"rt-1","expires_in":3599}
    """.utf8)

    @Test("the authorization URL is built from the configured endpoint, id and scopes")
    func authorizationURLFromInputs() throws {
        let client = OAuthTokenClient(configuration: makeConfiguration(clientSecret: "shh"))
        let url = client.authorizationURL(redirectURI: "http://localhost:7654",
                                          verifier: "verifier-value", state: "state-value")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.host == "auth.example.test")
        #expect(url.path == "/authorize")
        #expect(value("client_id") == "cid")
        #expect(value("redirect_uri") == "http://localhost:7654")
        #expect(value("response_type") == "code")
        #expect(value("scope") == "scope.a scope.b")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == PKCE.codeChallenge(for: "verifier-value"))
        #expect(value("state") == "state-value")
        // The client secret is never a query parameter.
        #expect(url.absoluteString.contains("shh") == false)
    }

    @Test("additional parameters are appended and may override a default")
    func additionalParameters() throws {
        let client = OAuthTokenClient(configuration: makeConfiguration(clientSecret: nil))
        let url = client.authorizationURL(redirectURI: "http://localhost:1",
                                          verifier: "v", state: "s",
                                          additionalParameters: ["access_type": "offline",
                                                                 "scope": "override"])
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "scope" }.count == 1)
        #expect(items.first { $0.name == "scope" }?.value == "override")
        #expect(items.first { $0.name == "access_type" }?.value == "offline")
    }

    /// The fourth historical bug: the client secret is required on BOTH
    /// exchanges. A refresh without it fails with `invalid_client` an hour after
    /// a sign-in that looked completely successful.
    @Test("the client secret is sent on the authorization-code exchange AND on every refresh")
    func clientSecretOnBothExchanges() async throws {
        let log = RequestLog()
        StubURLProtocol.handler = { request in
            log.record(request)
            return (200, ["Content-Type": "application/json"], Self.tokenResponse)
        }
        defer { StubURLProtocol.handler = nil }

        let client = OAuthTokenClient(configuration: makeConfiguration(clientSecret: "secret-value"),
                                      session: StubURLProtocol.makeSession())

        let code = try await client.authorizationCode("the-code", verifier: "the-verifier",
                                                      redirectURI: "http://localhost:7654")
        let refreshed = try await client.refresh(refreshToken: "rt-1")

        #expect(code.accessToken == "at-1")
        #expect(code.refreshToken == "rt-1")
        #expect(code.expiresIn == 3599)
        #expect(refreshed.accessToken == "at-1")

        let bodies = log.all.map(\.body)
        #expect(bodies.count == 2)
        #expect(bodies[0].contains("grant_type=authorization_code"))
        #expect(bodies[0].contains("client_secret=secret-value"))
        #expect(bodies[0].contains("code_verifier=the-verifier"))
        #expect(bodies[1].contains("grant_type=refresh_token"))
        #expect(bodies[1].contains("client_secret=secret-value"))
        #expect(log.all.allSatisfy { $0.url == "https://auth.example.test/token" })
    }

    @Test("a public client with no secret omits the parameter rather than sending an empty one")
    func noSecretOmitsParameter() async throws {
        let log = RequestLog()
        StubURLProtocol.handler = { request in
            log.record(request)
            return (200, [:], Self.tokenResponse)
        }
        defer { StubURLProtocol.handler = nil }

        let client = OAuthTokenClient(configuration: makeConfiguration(clientSecret: nil),
                                      session: StubURLProtocol.makeSession())
        _ = try await client.refresh(refreshToken: "rt-1")

        #expect(log.all.count == 1)
        #expect(log.all[0].body.contains("client_secret") == false)
    }

    @Test("a non-200 surfaces the provider's message and never the client secret")
    func errorNeverCarriesTheSecret() async throws {
        StubURLProtocol.handler = { _ in
            (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = OAuthTokenClient(configuration: makeConfiguration(clientSecret: "secret-value"),
                                      session: StubURLProtocol.makeSession())
        do {
            _ = try await client.refresh(refreshToken: "rt-1")
            Issue.record("a 400 must throw")
        } catch let error as MailError {
            let described = "\(error)"
            #expect(described.contains("invalid_grant"))
            #expect(described.contains("secret-value") == false)
        }
    }

    @Test("an undecodable 200 body is a typed decoding failure, not a crash")
    func undecodableBody() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data("not json".utf8)) }
        defer { StubURLProtocol.handler = nil }

        let client = OAuthTokenClient(configuration: makeConfiguration(clientSecret: nil),
                                      session: StubURLProtocol.makeSession())
        await #expect(throws: MailError.decodingFailed("token response")) {
            _ = try await client.refresh(refreshToken: "rt-1")
        }
    }
}

/// The storage invariant, asserted end-to-end over the production code path:
/// the refresh token reaches `host.secrets` and nothing else; the access token
/// stays in memory.
///
/// The invariant is STRUCTURAL — the auth types take a `PluginSecretStore` and
/// never a `PluginDocumentStore`, so there is no document a token could be
/// written to — and it is asserted structurally below rather than by handing a
/// document store to something that cannot accept one. An earlier version of
/// this suite did the latter: it built an `InMemoryDocumentStore`, passed it
/// nowhere, and asserted the untouched local was empty. That passes whether or
/// not the invariant holds, and would have kept passing if a later task gave
/// `GmailAuth` a document store and wrote a refresh token straight through it.
@Suite("OAuth token storage")
@MainActor
struct OAuthTokenStorageTests {
    /// The tripwire the vacuous version could not be: if any auth type ever
    /// gains a document-store dependency, this fails and whoever added it has to
    /// come here and justify it. Source-text assertion, in the same spirit as
    /// `RFC822BuilderTests`' backend-independence check.
    @Test("the auth layer has no document-store dependency to leak through")
    func authLayerCannotReachDocuments() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RavenFeatureTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
        let files = ["Sources/RavenFeature/Auth/OAuthTokenClient.swift",
                     "Sources/RavenFeature/Auth/LoopbackCallbackListener.swift",
                     "Sources/RavenFeature/Auth/PKCE.swift",
                     "Sources/RavenFeature/Provider/Gmail/GmailAuth.swift"]
        for path in files {
            let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            // Comments are stripped first, because these files SHOULD discuss the
            // invariant in prose — the whole point of the documentation carried
            // across from `GmailAuth` is to say that tokens never reach a
            // document store. Only code counts as reaching one.
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
            #expect(code.contains("PluginDocumentStore") == false,
                    "\(path) must not reach a document store — tokens live in secrets only")
            #expect(code.contains("host.documents") == false, "\(path)")
        }
    }

    @Test("no token string is ever written through PluginDocumentStore")
    func tokensNeverReachDocuments() async throws {
        let secrets = InMemorySecretStore()
        StubURLProtocol.handler = { request in
            if request.url?.path.contains("userinfo") == true {
                return (200, [:], Data(#"{"email":"a@example.test"}"#.utf8))
            }
            return (200, [:], Data("""
            {"access_token":"access-token-secret","refresh_token":"refresh-token-secret","expires_in":3599}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let auth = GmailAuth(secrets: secrets, clientID: "cid", clientSecret: "csecret",
                             session: StubURLProtocol.makeSession())
        let result = try await auth.completeAuthorization(code: "the-code", verifier: "v",
                                                          redirectURI: "http://localhost:1")

        #expect(result.address == "a@example.test")
        // Refresh token: in the Keychain-backed secret store, under the account key.
        #expect(secrets.secret(forKey: "refresh-a@example.test") == "refresh-token-secret")
        // Access token: memory only.
        #expect(auth.accessTokens["a@example.test"]?.token == "access-token-secret")

        // The secret store holds the refresh token and NOTHING else — in
        // particular not the access token and not the client secret, both of
        // which would otherwise be plausible things to cache next to it.
        let stored = secrets.allSecrets()
        #expect(stored == ["refresh-a@example.test": "refresh-token-secret"])
        #expect(stored.values.contains("access-token-secret") == false)
        #expect(stored.values.contains("csecret") == false)

        // And a sign-out clears the secret rather than leaving it behind.
        auth.signOut(accountID: "a@example.test")
        #expect(secrets.secret(forKey: "refresh-a@example.test") == nil)
        #expect(auth.accessTokens["a@example.test"] == nil)
    }
}
