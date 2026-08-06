import Foundation
import Security

/// Gmail's outgoing-message builder: the two decisions that are Gmail's own,
/// over the backend-independent assembly in `RFC822Builder`.
///
/// The generic part — `multipart/alternative`, attachments, the ICS reply part,
/// base64 CTE, CRLF canonicalisation and the S/MIME envelope — moved to
/// `MIME/RFC822Builder.swift` so IMAP `APPEND` and SMTP submission produce the
/// same bytes. Nothing changed in the extraction, and the members here keep
/// their exact access levels, so `GmailProviderTests` still reaches
/// `rfc822(_:identityLookup:)` the same way.
extension GmailProvider {
    /// The RFC 822 message, base64url encoded as Gmail's `raw` field requires.
    ///
    /// **Bcc, and why the header is present rather than suppressed.**
    ///
    /// The instinct — "Bcc must not appear in the transmitted headers, so
    /// don't emit it" — produces a message that is never delivered to the
    /// blind recipients at all. `messages/send` with `raw` hands Gmail a
    /// complete RFC822 message and NO separate envelope: there is no `bcc`
    /// request field, and the only way to name a recipient is a header. Gmail
    /// parses `To`, `Cc` and `Bcc` to build the SMTP envelope, then removes
    /// the `Bcc` header before the message is handed to any recipient, exactly
    /// as an MTA is required to (RFC 5322 §3.6.3 explicitly sanctions removing
    /// it at the first hop). So the header is present in what we upload and
    /// absent from what anyone receives — which is the correct outcome,
    /// achieved by the only mechanism this API offers.
    ///
    /// The copy Gmail files in the sender's own Sent mailbox does retain the
    /// header, which is also right: the sender is entitled to know who they
    /// blind-copied.
    ///
    /// This reasoning is true of *this* channel only, which is why
    /// `includeBccHeader` is a parameter of `RFC822Builder` and not a policy
    /// baked into it: a backend that submits over SMTP names blind recipients
    /// in the envelope (`RCPT TO`) and must NOT transmit the header.
    ///
    /// `identityLookup` defaults to a real `SecIdentityCopyPreferred` query
    /// against the account's email — tests inject a closure that instead looks
    /// an identity up in a throwaway test keychain, so no test ever touches
    /// the real login keychain (see `SMIME.preferredIdentity`).
    static func rfc822(
        _ message: OutgoingMessage,
        identityLookup: (String) -> SecIdentity? = { SMIME.preferredIdentity(email: $0) }
    ) -> String {
        toRawBase64URL(
            RFC822Builder.message(
                message, includeBccHeader: true, identityLookup: identityLookup))
    }

    /// Gmail's `raw` field: the whole RFC 822 message, base64url encoded.
    private static func toRawBase64URL(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
