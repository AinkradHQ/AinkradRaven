import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Task 19's first criterion: Graph reuses Task 4's OAuth layer rather than
/// growing a second flow, and its credentials land in the right stores.
@Suite("Graph auth")
@MainActor
struct GraphAuthTests {
    private func fixture(_ name: String) throws -> Data { try graphFixture(name) }

    /// The same deadline every Graph suite uses — see `graphBounded`. Every
    /// exchange below goes through `StubURLProtocol`, but a regression that
    /// reached the real network (or the real loopback listener) must fail this
    /// run in ten seconds rather than stall it.
    private func bounded<T: Sendable>(_ label: String,
                                      sourceLocation: SourceLocation = #_sourceLocation,
                                      _ body: @MainActor @escaping () async throws -> T)
        async throws -> T {
        try await graphBounded(label, sourceLocation: sourceLocation, body)
    }

    // MARK: Zero second OAuth flow

    /// The structural half of "zero second OAuth flow": the loopback listener
    /// is `Auth/`'s, so nothing under `Provider/Graph/` may bind a socket.
    ///
    /// A source-text tripwire, in the same spirit as
    /// `OAuthTokenStorageTests.authLayerCannotReachDocuments`, and for the same
    /// reason: a behavioural test cannot observe the ABSENCE of a second
    /// implementation — a hand-rolled listener that happened to work would pass
    /// every functional assertion in this file. Comments are stripped first, so
    /// the prose in `GraphAuth` that explains this rule cannot trip it.
    @Test("no file under Provider/Graph binds its own listener — the loopback flow is Auth/'s")
    func graphHasNoSecondListener() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RavenFeatureTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
        let directory = root.appending(path: "Sources/RavenFeature/Provider/Graph")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        // The check is worthless if it scanned nothing — this is the "asserted
        // on state something else made inert" shape.
        #expect(names.count >= 4, "expected the Graph provider's sources, found \(names)")

        for name in names.sorted() {
            let source = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
            #expect(code.contains("NWListener") == false,
                    "\(name) must not bind its own listener — use Auth/LoopbackCallbackListener")
            #expect(code.contains("import Network") == false, "\(name)")
            // PKCE is derived in one place too, not re-derived per provider.
            #expect(code.contains("SHA256") == false, "\(name)")
        }
    }

    /// The behavioural half: the URL that actually opens in the browser.
    @Test("the authorization URL is tenant-scoped and carries the S256 PKCE challenge")
    func authorizationURLIsTenantScopedWithPKCE() throws {
        let url = GraphAuth.authorizationURL(clientID: "azure-client-id",
                                             redirectURI: "http://localhost:7654",
                                             verifier: "verifier-value", state: "state-value",
                                             tenantID: "tenant-abc")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(components.host == "login.microsoftonline.com")
        // Tenant-scoped: the directory id is IN the path. A build that sent
        // every tenant to `/common` would still authorize, so this asserts the
        // whole path rather than merely that it contains the tenant.
        #expect(components.path == "/tenant-abc/oauth2/v2.0/authorize")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == PKCE.codeChallenge(for: "verifier-value"))
        // …and the challenge is genuinely derived, not the verifier echoed.
        #expect(value("code_challenge") != "verifier-value")
        #expect(value("client_id") == "azure-client-id")
        #expect(value("response_type") == "code")
        #expect(value("state") == "state-value")
        #expect(value("redirect_uri") == "http://localhost:7654")
    }

    @Test("the default tenant is the multi-tenant common endpoint")
    func defaultTenantIsCommon() throws {
        let url = GraphAuth.authorizationURL(clientID: "cid", redirectURI: "http://localhost:1",
                                             verifier: "v", state: "s")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/common/oauth2/v2.0/authorize")
    }

    /// `offline_access` is what makes Microsoft issue a refresh token at all.
    /// Without it the account silently stops syncing an hour after a sign-in
    /// that looked completely successful — the exact Google failure Task 4
    /// documented, in Microsoft's spelling.
    @Test("the requested scopes include offline_access, Mail.ReadWrite and Mail.Send")
    func scopesRequestOfflineAccess() throws {
        let url = GraphAuth.authorizationURL(clientID: "cid", redirectURI: "http://localhost:1",
                                             verifier: "v", state: "s")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let scope = try #require(items.first { $0.name == "scope" }?.value)
        #expect(scope.contains("offline_access"))
        #expect(scope.contains("https://graph.microsoft.com/Mail.ReadWrite"))
        #expect(scope.contains("https://graph.microsoft.com/Mail.Send"))
    }

    // MARK: Token storage

    /// The storage invariant, over the production code path: refresh token to
    /// `host.secrets` and NOTHING else there; access token in memory only.
    /// Exhaustive on the secret store — checking known keys can only prove what
    /// is present, and the interesting question is what else got written.
    @Test("the refresh token reaches host.secrets and the access token stays in memory")
    func refreshTokenToSecretsAccessTokenInMemory() async throws {
        let secrets = InMemorySecretStore()
        let profile = try fixture("graph-profile")
        StubURLProtocol.handler = { request in
            if request.url?.host == "graph.microsoft.com" { return (200, [:], profile) }
            return (200, [:], Data("""
            {"access_token":"graph-access-secret","refresh_token":"graph-refresh-secret","expires_in":3599}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let auth = GraphAuth(secrets: secrets, clientID: "azure-client-id",
                             clientSecret: "azure-client-secret", tenantID: "tenant-abc",
                             session: StubURLProtocol.makeSession())
        let result = try await bounded("completeAuthorization") {
            try await auth.completeAuthorization(code: "the-code", verifier: "v",
                                                 redirectURI: "http://localhost:1")
        }

        // `mail`, not `userPrincipalName` — the fixture deliberately makes them
        // DIFFERENT, so reading the wrong field is a failure and not a tie.
        #expect(result.address == "a@example.test")
        #expect(result.accountID == "a@example.test")

        #expect(auth.accessTokens["a@example.test"]?.token == "graph-access-secret")

        let stored = secrets.allSecrets()
        #expect(stored == ["graph-refresh-a@example.test": "graph-refresh-secret"])
        #expect(stored.values.contains("graph-access-secret") == false)
        #expect(stored.values.contains("azure-client-secret") == false)

        auth.signOut(accountID: "a@example.test")
        #expect(secrets.secret(forKey: "graph-refresh-a@example.test") == nil)
        #expect(auth.accessTokens["a@example.test"] == nil)
    }

    /// One address, two backends. Gmail files its refresh token under
    /// `refresh-<id>`; if Graph used the same key, connecting the second
    /// account would overwrite the first's token and sign the user out of a
    /// mailbox they never touched.
    @Test("Graph's refresh key does not collide with Gmail's for the same address")
    func refreshKeysDoNotCollideAcrossBackends() async throws {
        let secrets = InMemorySecretStore()
        let profile = try fixture("graph-profile")
        StubURLProtocol.handler = { request in
            if request.url?.host == "graph.microsoft.com" { return (200, [:], profile) }
            if request.url?.host == "www.googleapis.com" {
                return (200, [:], Data(#"{"email":"a@example.test"}"#.utf8))
            }
            let google = request.url?.host == "oauth2.googleapis.com"
            let refresh = google ? "google-refresh" : "graph-refresh"
            return (200, [:], Data("""
            {"access_token":"at","refresh_token":"\(refresh)","expires_in":3599}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let session = StubURLProtocol.makeSession()

        let gmail = GmailAuth(secrets: secrets, clientID: "cid", clientSecret: "cs",
                              session: session)
        _ = try await bounded("gmail completeAuthorization") {
            try await gmail.completeAuthorization(code: "c", verifier: "v",
                                                  redirectURI: "http://localhost:1")
        }
        let graph = GraphAuth(secrets: secrets, clientID: "azure", session: session)
        _ = try await bounded("graph completeAuthorization") {
            try await graph.completeAuthorization(code: "c", verifier: "v",
                                                  redirectURI: "http://localhost:1")
        }

        #expect(secrets.allSecrets() == [
            "refresh-a@example.test": "google-refresh",
            "graph-refresh-a@example.test": "graph-refresh",
        ])
        // And signing out of one leaves the other's token intact.
        graph.signOut(accountID: "a@example.test")
        #expect(secrets.secret(forKey: "refresh-a@example.test") == "google-refresh")
    }

    /// A public (desktop) Azure registration is issued NO secret, so the
    /// parameter must be omitted entirely rather than sent empty — an empty
    /// `client_secret` is rejected as `invalid_client`, an hour after a
    /// successful-looking sign-in.
    @Test("a public registration sends no client_secret on the refresh exchange")
    func publicClientOmitsSecret() async throws {
        let bodies = RecordedBodies()
        StubURLProtocol.handler = { request in
            bodies.record(request)
            return (200, [:], Data(#"{"access_token":"at","expires_in":3599}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let secrets = InMemorySecretStore()
        secrets.setSecret("rt", forKey: "graph-refresh-a@example.test")
        let auth = GraphAuth(secrets: secrets, clientID: "azure", clientSecret: nil,
                             session: StubURLProtocol.makeSession())
        _ = try await bounded("accessToken") {
            try await auth.accessToken(accountID: "a@example.test")
        }

        let all = bodies.all
        #expect(all.count == 1)
        #expect(all.first?.contains("grant_type=refresh_token") == true)
        #expect(all.first?.contains("client_secret") == false)
    }

    /// No stored refresh token is `notAuthenticated`, by account id — never a
    /// crash and never a silent empty token that would produce a confusing 401
    /// three layers down.
    @Test("an account with no stored refresh token cannot produce an access token")
    func missingRefreshTokenIsNotAuthenticated() async throws {
        let auth = GraphAuth(secrets: InMemorySecretStore(), clientID: "azure",
                             session: StubURLProtocol.makeSession())
        await #expect(throws: MailError.notAuthenticated(accountID: "ghost@example.test")) {
            try await self.bounded("accessToken(no refresh token)") {
                _ = try await auth.accessToken(accountID: "ghost@example.test")
            }
        }
    }
}
