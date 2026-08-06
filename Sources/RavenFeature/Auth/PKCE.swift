import Foundation
import CryptoKit

// Lifted verbatim (bodies unchanged) out of the provider-specific auth type
// these helpers used to live on, which also knew one provider's endpoints — see
// git history for the move. RFC 7636 has nothing provider-specific in it: the
// verifier is random bytes, the challenge is its SHA-256 in base64url, and
// `state` is more random bytes. Three consumers now need exactly that (a
// provider's REST API flow, the same provider's XOAUTH2 flow, and Azure), so it
// lives here with no notion of who is asking. This directory deliberately
// contains no provider name at all.

/// RFC 7636 PKCE helpers, plus the `state` parameter that guards the redirect.
public enum PKCE {
    /// 64 random bytes, base64url'd — comfortably above RFC 7636's 43-character
    /// minimum for the encoded verifier.
    public static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// The `S256` challenge for a verifier. The only method Raven offers —
    /// `plain` is permitted by the RFC and is not worth supporting.
    public static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A random, unguessable value for the `state` parameter. Reuses the same
    /// entropy source as `codeVerifier()` — both just need a long random
    /// base64url string.
    public static func randomState() -> String { codeVerifier() }

    /// base64url, unpadded (RFC 4648 §5), which is what both the PKCE
    /// challenge and the verifier must be.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
