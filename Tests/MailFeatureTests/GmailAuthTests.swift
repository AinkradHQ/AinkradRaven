import Testing
import Foundation
@testable import MailFeature

@Suite("Gmail auth")
@MainActor
struct GmailAuthTests {
    @Test("the authorization URL carries PKCE, offline access, and the right scopes")
    func authorizationURL() throws {
        let verifier = GmailAuth.codeVerifier()
        let url = GmailAuth.authorizationURL(clientID: "cid.apps.googleusercontent.com",
                                             redirectURI: "http://127.0.0.1:7654",
                                             verifier: verifier)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.host == "accounts.google.com")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == GmailAuth.codeChallenge(for: verifier))
        #expect(value("access_type") == "offline")
        #expect(value("prompt") == "consent")
        let scope = try #require(value("scope"))
        #expect(scope.contains("gmail.modify"))
        #expect(scope.contains("gmail.send"))
        #expect(scope.contains("gmail.readonly") == false)
    }

    @Test("a verifier is long enough to satisfy RFC 7636 and differs per call")
    func verifierEntropy() {
        let first = GmailAuth.codeVerifier()
        #expect(first.count >= 43)
        #expect(first != GmailAuth.codeVerifier())
    }

    @Test("the challenge is base64url with no padding")
    func challengeEncoding() {
        let challenge = GmailAuth.codeChallenge(for: "abc123")
        #expect(challenge.contains("=") == false)
        #expect(challenge.contains("+") == false)
        #expect(challenge.contains("/") == false)
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
        let auth = GmailAuth(secrets: secrets, clientID: "cid") { _ in
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
        let auth = GmailAuth(secrets: secrets, clientID: "cid") { refresh in
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
        let auth = GmailAuth(secrets: secrets, clientID: "cid") { _ in
            Issue.record("refresh should not be attempted without a stored refresh token")
            return ("unused", 0)
        }

        await #expect(throws: MailError.notAuthenticated(accountID: "acct")) {
            try await auth.accessToken(accountID: "acct")
        }
    }
}
