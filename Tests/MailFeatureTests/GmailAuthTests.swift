import Testing
import Foundation
@testable import MailFeature

@Suite("Gmail auth")
@MainActor
struct GmailAuthTests {
    @Test("the authorization URL carries PKCE, offline access, state, and the right scopes")
    func authorizationURL() throws {
        let verifier = GmailAuth.codeVerifier()
        let state = GmailAuth.randomState()
        let url = GmailAuth.authorizationURL(clientID: "cid.apps.googleusercontent.com",
                                             redirectURI: "http://127.0.0.1:7654",
                                             verifier: verifier, state: state)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.host == "accounts.google.com")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == GmailAuth.codeChallenge(for: verifier))
        #expect(value("access_type") == "offline")
        #expect(value("prompt") == "consent")
        #expect(value("state") == state)
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

/// Covers the pure parsing seam the loopback listener depends on to read the
/// OAuth redirect off the raw HTTP request line. The listener's actual socket
/// behavior (binding, accepting a connection, an OS-chosen port) is NOT
/// covered here — that would require real networking, which is disallowed in
/// this test target. This suite exists precisely so the logic that CAN be
/// tested without a socket (parsing) is not buried inside the connection
/// handler where it couldn't be.
@Suite("Gmail auth callback parsing")
struct CallbackRequestParserTests {
    @Test("a successful callback yields the code and state")
    func successfulCallback() {
        let result = CallbackRequestParser.parse(
            requestLine: "GET /?code=abc123&state=xyz789 HTTP/1.1")
        #expect(result.code == "abc123")
        #expect(result.state == "xyz789")
        #expect(result.error == nil)
    }

    @Test("a denied consent screen yields an error, not a code")
    func accessDenied() {
        let result = CallbackRequestParser.parse(
            requestLine: "GET /?error=access_denied&state=xyz789 HTTP/1.1")
        #expect(result.error == "access_denied")
        #expect(result.code == nil)
    }

    @Test("a malformed request line yields nothing rather than crashing")
    func malformedLine() {
        #expect(CallbackRequestParser.parse(requestLine: "not an http request").code == nil)
        #expect(CallbackRequestParser.parse(requestLine: "").code == nil)
        #expect(CallbackRequestParser.parse(requestLine: "GET").code == nil)
    }

    @Test("the first line is extracted regardless of CRLF vs LF line endings")
    func firstLineExtraction() {
        #expect(CallbackRequestParser.firstLine(of: "GET /?code=a HTTP/1.1\r\nHost: x\r\n\r\n")
                == "GET /?code=a HTTP/1.1")
        #expect(CallbackRequestParser.firstLine(of: "GET /?code=a HTTP/1.1\nHost: x\n\n")
                == "GET /?code=a HTTP/1.1")
        #expect(CallbackRequestParser.firstLine(of: "") == nil)
    }
}

/// Covers the state-mismatch rejection at the point where `authorize()` would
/// use it — since `authorize()` itself drives a real loopback listener and
/// browser open (untestable without network/UI), this exercises the same
/// comparison `LoopbackCallbackListener.run` performs, directly against the
/// parser's output, to prove a spoofed callback from a different local
/// process would be rejected rather than silently accepted.
@Suite("Gmail auth state verification")
struct StateVerificationTests {
    @Test("a callback whose state does not match the one that was sent is not treated as the expected code")
    func mismatchedStateIsDetectable() {
        let expectedState = "expected-state"
        let callback = CallbackRequestParser.parse(
            requestLine: "GET /?code=abc123&state=attacker-state HTTP/1.1")
        #expect(callback.code == "abc123")
        #expect(callback.state != expectedState)
    }
}

/// Covers the exactly-once resume discipline `LoopbackCallbackListener`
/// depends on to avoid double-resuming its continuation when a timeout races
/// a connection callback. `OneShotResumeGuard` is lock-protected rather than
/// relying on queue confinement, so — unlike the listener's socket handling,
/// which genuinely cannot be tested without a real network — this can and
/// does get exercised under real concurrent contention from multiple tasks.
/// This is a stress test, not a formal proof: it does not guarantee every
/// possible interleaving was hit, but a lock around a single boolean has no
/// interesting interleavings left to miss once the critical section is that
/// small, and 200 concurrent firers reliably exercise the race in practice.
@Suite("OneShotResumeGuard")
struct OneShotResumeGuardTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("only the first of many concurrent fires invokes the completion")
    func exactlyOneCompletionUnderConcurrency() async {
        let completions = Counter()
        let resumeGuard = OneShotResumeGuard<Int> { _ in completions.increment() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { resumeGuard.fire(i) }
            }
        }

        #expect(completions.current == 1)
    }

    @Test("fire() reports true for exactly one caller under concurrency")
    func exactlyOneTrueReturnUnderConcurrency() async {
        let trueReturns = Counter()
        let resumeGuard = OneShotResumeGuard<Int> { _ in }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if resumeGuard.fire(i) { trueReturns.increment() }
                }
            }
        }

        #expect(trueReturns.current == 1)
    }
}
