import Foundation

/// The SASL payloads Raven's two wire protocols share, byte for byte.
///
/// **Why this file exists rather than a second copy inside `SMTPSession`.**
/// IMAP (`AUTHENTICATE PLAIN <base64>` / a bare continuation line) and SMTP
/// (`AUTH PLAIN <base64>`) differ only in *command framing*. The credential
/// payload itself — RFC 4616's `authzid \0 authcid \0 passwd` and Google's
/// `user=<addr>\u{01}auth=Bearer <token>\u{01}\u{01}` — is identical, and it is
/// the part where a wrong byte is invisible until a live server refuses the
/// login. Two copies of it would be two things to get right; this is one, and
/// `IMAPAuthTests` already pins the bytes it produces.
///
/// Nothing here stores, logs or formats a credential for display. Every function
/// is pure: secrets arrive as parameters and leave as the exact bytes the wire
/// needs. There is deliberately no `description`, no error type, and no store
/// reference in this file — the same structural property `IMAPCredential`
/// documents for the IMAP path.
enum SASLMechanism {
    /// SASL `PLAIN` (RFC 4616): `authzid \0 authcid \0 passwd`, with an empty
    /// authorization identity. Pre-base64, so a test can assert the exact byte
    /// layout including the NUL separators.
    static func plainInitialResponse(username: String, password: String) -> Data {
        var bytes = Data([0x00])
        bytes.append(Data(username.utf8))
        bytes.append(0x00)
        bytes.append(Data(password.utf8))
        return bytes
    }

    /// SASL `XOAUTH2`, exactly `user=<addr>\u{01}auth=Bearer <token>\u{01}\u{01}`
    /// where `\u{01}` is the `^A` separator the mechanism specifies. Pre-base64.
    static func xoauth2InitialResponse(username: String, accessToken: String) -> Data {
        Data("user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8)
    }

    static func base64(_ data: Data) -> String { data.base64EncodedString() }
}
