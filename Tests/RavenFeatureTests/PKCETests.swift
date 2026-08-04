import Testing
import Foundation
@testable import RavenFeature

/// Moved out of `GmailAuthTests` when PKCE was extracted into the
/// provider-neutral `Auth/` layer. Same assertions, same expectations — only
/// the type they are addressed to changed (`GmailAuth` → `PKCE`).
@Suite("PKCE")
struct PKCETests {
    @Test("a verifier is long enough to satisfy RFC 7636 and differs per call")
    func verifierEntropy() {
        let first = PKCE.codeVerifier()
        #expect(first.count >= 43)
        #expect(first != PKCE.codeVerifier())
    }

    @Test("the challenge is base64url with no padding")
    func challengeEncoding() {
        let challenge = PKCE.codeChallenge(for: "abc123")
        #expect(challenge.contains("=") == false)
        #expect(challenge.contains("+") == false)
        #expect(challenge.contains("/") == false)
    }

    @Test("the challenge is a deterministic S256 digest of the verifier")
    func challengeIsDeterministic() {
        #expect(PKCE.codeChallenge(for: "abc123") == PKCE.codeChallenge(for: "abc123"))
        #expect(PKCE.codeChallenge(for: "abc123") != PKCE.codeChallenge(for: "abc124"))
    }

    @Test("state reuses the verifier's entropy source and is unguessable per call")
    func stateEntropy() {
        let state = PKCE.randomState()
        #expect(state.count >= 43)
        #expect(state != PKCE.randomState())
    }
}
