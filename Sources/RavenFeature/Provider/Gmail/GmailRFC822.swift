import Foundation
import Security

/// Gmail's outgoing-message builder: the whole RFC 822 assembly, plus its S/MIME
/// envelope and the small helpers only it uses.
///
/// Split out of `GmailProvider` to keep both files under the 500-line cap.
/// Nothing changed in the move — the members keep their exact access levels, so
/// `GmailProviderTests` still reaches `rfc822(_:identityLookup:)` the same way.
extension GmailProvider {
    /// RFC822, base64url encoded as Gmail's `raw` field requires.
    ///
    /// **Every** header line is built by `MIMEHeader`, which sanitizes each
    /// value before encoding it. That is not stylistic: `RFC2047.encode`
    /// returns pure-ASCII input unchanged, so nothing used to validate an
    /// ASCII header value, and reply/forward subjects come from
    /// `thread.subject` while `In-Reply-To` is a raw remote `Message-ID` —
    /// both attacker-controlled. A subject of `"hello\r\nBcc: evil@x"` emitted
    /// a real `Bcc:` header. See `MIMEHeader` for why nothing here formats a
    /// `"Name: value"` string itself.
    ///
    /// `Subject` and any `To`/`Cc` display name is RFC 2047 encoded-word
    /// wrapped whenever it contains non-ASCII — RFC 5322 header field bodies
    /// are ASCII-only. A pure-ASCII value is left unencoded.
    ///
    /// The body is sent as `multipart/alternative`:
    /// - the plain part is `bodyText` as typed — including the
    ///   `body + "\n-- \n" + signature` its callers assembled — with only its
    ///   line endings normalised to CRLF, which RFC 2046 requires of a `text/*`
    ///   part and boundary recognition depends on. A bare `\n` in a MIME
    ///   structure this picky is exactly how a recipient ends up seeing raw
    ///   boundary markers;
    /// - the HTML part renders that same text via
    ///   `MarkdownToHTML.renderComposed`, which splits the signature off before
    ///   parsing so the sigdash is never mistaken for a setext heading.
    ///
    /// Both parts declare `Content-Transfer-Encoding: base64` and are actually
    /// base64d. They previously emitted raw UTF-8 under an implicit `7bit`,
    /// which was untrue of the bytes and left one long typed paragraph free to
    /// blow RFC 5322's 998-octet line limit. The boundary is a fresh random
    /// token checked against both parts before use, and every structural line
    /// uses CRLF.
    /// `identityLookup` defaults to a real `SecIdentityCopyPreferred` query
    /// against the account's email — tests inject a closure that instead
    /// looks an identity up in a throwaway test keychain, so no test ever
    /// touches the real login keychain (see `SMIME.preferredIdentity`).
    static func rfc822(
        _ message: OutgoingMessage,
        identityLookup: (String) -> SecIdentity? = { SMIME.preferredIdentity(email: $0) }
    ) -> String {
        // Base direction, set once on a wrapper rather than reimplemented.
        //
        // An Arabic message rendered inside an implicitly `dir="ltr"` document
        // has every paragraph flush left and its trailing punctuation at the
        // wrong end — the Unicode bidi algorithm reorders the runs correctly
        // and cannot guess the PARAGRAPH direction, which is what `dir`
        // supplies. Emitted only for `rtl`, so an English message's HTML part
        // is byte-for-byte what it always was.
        let rendered = MarkdownToHTML.renderComposed(message.bodyText)
        let html: String
        switch BaseTextDirection.detect(message.bodyText) {
        case .leftToRight: html = rendered
        case .rightToLeft: html = "<div dir=\"rtl\">\(rendered)</div>"
        }
        let icsText = message.icsReply?.icsText ?? ""
        // Every text part any boundary must be checked against — attachment
        // bytes are excluded deliberately: they are base64 (an alphabet with
        // no `-`), so the hyphenated `raven-<uuid>` boundary token cannot
        // occur inside them, and checking megabytes of base64 text here would
        // be pure waste.
        let innerBoundary = randomBoundary(avoiding: [message.bodyText, html, icsText])
        let alternative = [
            "--\(innerBoundary)",
            MIMEHeader.literalLine("Content-Type", "text/plain; charset=UTF-8"),
            MIMEHeader.literalLine("Content-Transfer-Encoding", "base64"),
            "",
            MIMEHeader.base64Body(message.bodyText),
            "--\(innerBoundary)",
            MIMEHeader.literalLine("Content-Type", "text/html; charset=UTF-8"),
            MIMEHeader.literalLine("Content-Transfer-Encoding", "base64"),
            "",
            MIMEHeader.base64Body(html),
            "--\(innerBoundary)--",
            "",
        ].joined(separator: "\r\n")

        var lines = [
            MIMEHeader.addressLine("To", message.to),
            MIMEHeader.line("Subject", message.subject),
            MIMEHeader.literalLine("MIME-Version", "1.0"),
        ]
        if !message.cc.isEmpty {
            lines.append(MIMEHeader.addressLine("Cc", message.cc))
        }
        // **Bcc, and why the header is here rather than suppressed.**
        //
        // The instinct — "Bcc must not appear in the transmitted headers, so
        // don't emit it" — produces a message that is never delivered to the
        // blind recipients at all. `messages/send` with `raw` hands Gmail a
        // complete RFC822 message and NO separate envelope: there is no
        // `bcc` request field, and the only way to name a recipient is a
        // header. Gmail parses `To`, `Cc` and `Bcc` to build the SMTP
        // envelope, then removes the `Bcc` header before the message is
        // handed to any recipient, exactly as an MTA is required to (RFC 5322
        // §3.6.3 explicitly sanctions removing it at the first hop). So the
        // header is present in what we upload and absent from what anyone
        // receives — which is the correct outcome, achieved by the only
        // mechanism this API offers.
        //
        // The copy Gmail files in the sender's own Sent mailbox does retain
        // the header, which is also right: the sender is entitled to know who
        // they blind-copied.
        //
        // Same `MIMEHeader.addressLine` as every other header, so a display
        // name here is sanitized and RFC 2047 wrapped identically. That
        // matters more for this line than any other: the header-injection
        // vector `MIMEHeader` exists to close was literally "a subject that
        // smuggles in a `Bcc:`".
        if !message.bcc.isEmpty {
            lines.append(MIMEHeader.addressLine("Bcc", message.bcc))
        }
        if let inReplyTo = message.inReplyToMessageID {
            lines.append(MIMEHeader.literalLine("In-Reply-To", inReplyTo))
            lines.append(MIMEHeader.literalLine("References", inReplyTo))
        }

        // No attachments and no ICS reply: exactly the pre-M4 message —
        // `multipart/alternative` at the top level, unchanged byte-for-byte
        // when unsigned. This is deliberate, not an accident of refactoring:
        // every existing caller and test that never attaches anything must
        // keep getting the exact structure it always has.
        let contentTypeLine: String
        let body: String
        if message.attachments.isEmpty && message.icsReply == nil {
            contentTypeLine = MIMEHeader.literalLine(
                "Content-Type", "multipart/alternative; boundary=\"\(innerBoundary)\"")
            body = alternative
        } else {
            // Otherwise: an outer `multipart/mixed` wraps the `multipart/
            // alternative` text part plus one part per attachment and (if
            // present) the calendar-reply part. The outer boundary is rolled
            // separately from, and checked against, the inner one as well as
            // every text part — two boundaries that could collide would
            // corrupt whichever nests inside the other.
            var outerBoundary = randomBoundary(avoiding: [message.bodyText, html, icsText])
            while outerBoundary == innerBoundary {
                outerBoundary = randomBoundary(avoiding: [message.bodyText, html, icsText])
            }
            contentTypeLine = MIMEHeader.literalLine(
                "Content-Type", "multipart/mixed; boundary=\"\(outerBoundary)\"")

            var parts: [String] = [
                "--\(outerBoundary)",
                MIMEHeader.literalLine(
                    "Content-Type", "multipart/alternative; boundary=\"\(innerBoundary)\""),
                "",
                alternative,
            ]
            for attachment in message.attachments {
                parts.append("--\(outerBoundary)")
                parts.append(MIMEHeader.literalLine(
                    "Content-Type",
                    "\(attachment.mimeType); name=\"\(sanitizedASCIIName(attachment.filename))\""))
                parts.append(MIMEHeader.contentDispositionAttachment(filename: attachment.filename))
                parts.append(MIMEHeader.literalLine("Content-Transfer-Encoding", "base64"))
                parts.append("")
                parts.append(MIMEHeader.base64Body(attachment.data))
            }
            if let icsReply = message.icsReply {
                parts.append("--\(outerBoundary)")
                parts.append(MIMEHeader.literalLine(
                    "Content-Type", "text/calendar; method=REPLY; charset=UTF-8"))
                parts.append(MIMEHeader.literalLine("Content-Transfer-Encoding", "base64"))
                parts.append("")
                parts.append(MIMEHeader.base64Body(icsReply.icsText))
            }
            parts.append("--\(outerBoundary)--")
            parts.append("")
            body = parts.joined(separator: "\r\n")
        }

        // S/MIME signing is opt-in: only when the sending account has a
        // signing identity available does the message become
        // `multipart/signed`. No identity found (the overwhelming common
        // case in this environment — there is no real S/MIME identity
        // configured) means sending proceeds exactly as before, unsigned,
        // with no error raised.
        if let accountID = message.accountID, let identity = identityLookup(accountID),
           let signed = signedEnvelope(
               contentTypeLine: contentTypeLine, body: body,
               avoiding: [message.bodyText, html, icsText], identity: identity) {
            lines.append(signed.contentTypeLine)
            let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + signed.body
            return toRawBase64URL(raw)
        }

        lines.append(contentTypeLine)
        let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        return toRawBase64URL(raw)
    }

    /// Wraps `contentTypeLine` + `body` — an already-complete MIME entity —
    /// in `multipart/signed; protocol="application/pkcs7-signature"`: the
    /// entity is repeated byte-for-byte as the first part (so any client,
    /// S/MIME-aware or not, still renders the message), followed by a
    /// detached `application/pkcs7-signature` part carrying `SMIME.sign`'s
    /// output over the FIRST part's exact CRLF-canonical bytes. Returns `nil`
    /// (never throws) if `SMIME.sign` fails for any reason, so a caller can
    /// fall back to sending unsigned.
    private static func signedEnvelope(
        contentTypeLine: String, body: String, avoiding texts: [String], identity: SecIdentity
    ) -> (contentTypeLine: String, body: String)? {
        let canonical = SMIME.canonicalPart(headerLines: [contentTypeLine], body: body)
        guard let signature = SMIME.sign(content: canonical, identity: identity) else { return nil }

        var signedBoundary = randomBoundary(avoiding: texts)
        // The signed part's own bytes must never accidentally contain this
        // boundary either — its `avoiding` list already covers the plain
        // text/HTML/ICS bodies nested inside it, but re-checking against the
        // fully-assembled part is what actually matters here.
        while body.contains(signedBoundary) {
            signedBoundary = randomBoundary(avoiding: texts)
        }
        let envelopeContentType = MIMEHeader.literalLine(
            "Content-Type",
            "multipart/signed; protocol=\"application/pkcs7-signature\"; "
                + "micalg=sha-256; boundary=\"\(signedBoundary)\"")
        let envelopeBody = [
            "--\(signedBoundary)",
            contentTypeLine,
            "",
            body,
            "--\(signedBoundary)",
            MIMEHeader.literalLine(
                "Content-Type", "application/pkcs7-signature; name=\"smime.p7s\""),
            MIMEHeader.literalLine(
                "Content-Disposition", "attachment; filename=\"smime.p7s\""),
            MIMEHeader.literalLine("Content-Transfer-Encoding", "base64"),
            "",
            MIMEHeader.base64Body(signature),
            "--\(signedBoundary)--",
            "",
        ].joined(separator: "\r\n")
        return (envelopeContentType, envelopeBody)
    }

    /// Gmail's `raw` field: the whole RFC 822 message, base64url encoded.
    private static func toRawBase64URL(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A `Content-Type`'s `name=` parameter is, like `Content-Disposition`'s
    /// bare `filename=`, an RFC 5322 ASCII quoted-string — non-ASCII bytes
    /// are not legal inside it. `Content-Disposition`'s RFC 2231
    /// `filename*=` parameter (see `MIMEHeader.contentDispositionAttachment`)
    /// is the field a real client actually reads the display name from, so
    /// this one only needs a safe placeholder when the real name cannot fit.
    private static func sanitizedASCIIName(_ filename: String) -> String {
        guard filename.utf8.allSatisfy({ $0 <= 0x7F }) else { return "attachment" }
        return filename
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A boundary token guaranteed absent from every part it separates —
    /// otherwise a part containing a line that happens to match the boundary
    /// would truncate or corrupt the MIME structure. Astronomically unlikely
    /// with a fresh UUID per call, but checked (and re-rolled) rather than
    /// assumed.
    private static func randomBoundary(avoiding texts: [String]) -> String {
        var boundary = "raven-\(UUID().uuidString)"
        while texts.contains(where: { $0.contains(boundary) }) {
            boundary = "raven-\(UUID().uuidString)"
        }
        return boundary
    }
}
