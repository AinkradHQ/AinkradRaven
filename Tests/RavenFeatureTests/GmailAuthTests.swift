import Testing
import Foundation
@testable import RavenFeature

// What remains here after Task 4 is Gmail's *configuration* — the endpoint, the
// scopes, the offline-access parameters, and the token cache. The listener, the
// PKCE helpers, the form encoding and the token exchanges are shared now and are
// covered by `LoopbackCallbackListenerTests`, `PKCETests` and
// `OAuthTokenClientTests`.

@Suite("Gmail auth")
@MainActor
struct GmailAuthTests {
    @Test("the authorization URL carries PKCE, offline access, state, and the right scopes")
    func authorizationURL() throws {
        let verifier = PKCE.codeVerifier()
        let state = PKCE.randomState()
        let url = GmailAuth.authorizationURL(clientID: "cid.apps.googleusercontent.com",
                                             redirectURI: "http://127.0.0.1:7654",
                                             verifier: verifier, state: state)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.host == "accounts.google.com")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == PKCE.codeChallenge(for: verifier))
        #expect(value("access_type") == "offline")
        #expect(value("prompt") == "consent")
        #expect(value("state") == state)
        let scope = try #require(value("scope"))
        #expect(scope.contains("gmail.modify"))
        #expect(scope.contains("gmail.send"))
        #expect(scope.contains("gmail.readonly") == false)
    }
}

/// Covers the token-refresh cache logic in `accessToken(accountID:)`, which
/// runs on every provider request. Seeds the (internal, not private)
/// `accessTokens` cache directly via `@testable import` so no network call
/// or browser flow is needed; the refresh exchange itself is stubbed via the
/// injectable `refreshExchange` closure.
@Suite("Gmail auth token cache")
@MainActor
struct GmailAuthCacheTests {
    @Test("a cached token that is still comfortably valid is returned without a network call")
    func cachedTokenReturnedWithoutRefresh() async throws {
        let secrets = InMemorySecretStore()
        let auth = GmailAuth(secrets: secrets, clientID: "cid", clientSecret: "csecret") { _ in
            Issue.record("refresh should not be called for a still-valid cached token")
            return ("network-token", 3600)
        }
        auth.accessTokens["acct"] = ("cached-token", Date().addingTimeInterval(3600))

        let token = try await auth.accessToken(accountID: "acct")

        #expect(token == "cached-token")
    }

    @Test("a cached token within the 60-second expiry margin is treated as stale")
    func staleCachedTokenTriggersRefresh() async throws {
        let secrets = InMemorySecretStore()
        secrets.setSecret("stored-refresh-token", forKey: "refresh-acct")
        let auth = GmailAuth(secrets: secrets, clientID: "cid", clientSecret: "csecret") { refresh in
            #expect(refresh == "stored-refresh-token")
            return ("refreshed-token", 3600)
        }
        // Within the 60s margin: must be treated as stale, not returned as-is.
        auth.accessTokens["acct"] = ("stale-token", Date().addingTimeInterval(30))

        let token = try await auth.accessToken(accountID: "acct")

        #expect(token == "refreshed-token")
        #expect(auth.accessTokens["acct"]?.token == "refreshed-token")
    }

    @Test("no refresh token in the secret store throws notAuthenticated rather than returning something empty")
    func missingRefreshTokenThrows() async throws {
        let secrets = InMemorySecretStore()
        let auth = GmailAuth(secrets: secrets, clientID: "cid", clientSecret: "csecret") { _ in
            Issue.record("refresh should not be attempted without a stored refresh token")
            return ("unused", 0)
        }

        await #expect(throws: MailError.notAuthenticated(accountID: "acct")) {
            try await auth.accessToken(accountID: "acct")
        }
    }
}
