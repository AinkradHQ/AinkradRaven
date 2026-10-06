import AinkradAppKit
import Foundation
import Testing

@testable import RavenFeature

/// What `GmailProvider.rfc822` emits for `send()`: line endings, RFC 2047
/// headers, multipart structure, header injection and transfer encoding. Split
/// out of `GmailProviderTests`; the suite keeps its trait and isolation.
@Suite("Gmail send encoding", .stubbedNetwork)
@MainActor
struct GmailSendEncodingTests {
    // MARK: send() / raw RFC822 encoding

    @Test("send's raw RFC822 round-trips an ASCII subject and body correctly, and leaves the subject unencoded")
    func sendRoundTripsASCII() {
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")],
                subject: "Hello there",
                bodyText: "Line one\nLine two"))
        #expect(mime.headerBlock.contains("Subject: Hello there"))
        // RFC 2046 requires CRLF in a text part; the editor supplies bare `\n`.
        // This assertion used to read `contains("Line one\nLine two")`, which
        // asserted the bare-LF DEFECT as correct behaviour.
        #expect(mime.plain == "Line one\r\nLine two")
        #expect(mime.plain.contains("\n") == false || mime.plain.contains("\r\n"))
        // Encoding an ASCII-only subject is legal but ugly in some clients —
        // it must stay literal.
        #expect(mime.headerBlock.contains("=?UTF-8?B?") == false)
    }

    /// Explicitly: not one bare LF and not one bare CR anywhere in the emitted
    /// message — structure, part headers, or part content.
    @Test("no bare LF and no bare CR survives anywhere in the message, in either part")
    func everyLineEndingIsCRLF() {
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "s",
                bodyText: "Line one\nLine two\rLine three\r\nLine four"))

        let scalars = Array(mime.raw.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\n" {
                #expect(
                    index > 0 && scalars[index - 1] == "\r",
                    "bare LF at \(index)")
            }
            if scalar == "\r" {
                #expect(
                    index + 1 < scalars.count && scalars[index + 1] == "\n",
                    "bare CR at \(index)")
            }
        }
        #expect(mime.raw.contains("\r\r") == false)
        #expect(mime.plain == "Line one\r\nLine two\r\nLine three\r\nLine four")
    }

    // MARK: RFC 2047 subject encoding

    /// The headline defect this task fixes: a non-ASCII `Subject:` header
    /// must be RFC 2047 encoded-word wrapped, not emitted as literal UTF-8
    /// bytes RFC 5322 does not allow in a header field body.
    @Test("an Arabic subject is emitted as a valid RFC 2047 encoded word that decodes back byte-exact")
    func arabicSubjectEncodesAndDecodesExactly() {
        let subject = "مرحبا بكم في البريد"
        let message = OutgoingMessage(
            to: [MailAddress(email: "b@example.com")],
            subject: subject, bodyText: "body")
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""

        let subjectLine = decoded.split(separator: "\r\n")
            .reduce(into: [String]()) { lines, line in
                if line.hasPrefix("Subject:") || (line.hasPrefix(" ") && lines.last?.hasPrefix("Subject:") == true) {
                    lines.append(String(line))
                }
            }
        let header = subjectLine.joined(separator: "\r\n")
        #expect(header.contains("=?UTF-8?B?"))
        let value = header.replacingOccurrences(of: "Subject: ", with: "")
        #expect(RFC2047.decode(value) == subject)
    }

    /// A long non-ASCII subject must fold into multiple encoded words (each
    /// capped at 75 characters including delimiters) without ever splitting
    /// a multi-byte UTF-8 sequence across the fold — the classic bug that
    /// produces replacement characters in a recipient's client.
    @Test("a long non-ASCII subject folds across multiple encoded words without splitting a UTF-8 sequence")
    func longNonASCIISubjectFoldsWithoutSplittingUTF8() throws {
        let subject = String(repeating: "café ☕️ مرحبا ", count: 15)
        let encoded = RFC2047.encode(subject)

        // More than one encoded word was needed.
        let words = encoded.components(separatedBy: "\r\n ")
        #expect(words.count > 1)
        for word in words {
            #expect(word.count <= 75, "each encoded word must respect the 75-char RFC 2047 cap")
            #expect(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
        }

        // Decoding every word's base64 payload independently must never
        // fail to produce valid UTF-8 for that chunk — proof no scalar was
        // split across a fold boundary.
        for word in words {
            let base64 =
                word
                .replacingOccurrences(of: "=?UTF-8?B?", with: "")
                .replacingOccurrences(of: "?=", with: "")
            let data = try #require(Data(base64Encoded: base64))
            #expect(
                String(data: data, encoding: .utf8) != nil,
                "a chunk that isn't valid UTF-8 on its own means a scalar was split")
        }

        #expect(RFC2047.decode(encoded) == subject)
    }

    // MARK: BODY round-trip (Arabic + emoji, byte-exact)

    @Test("a body containing Arabic and emoji round-trips byte-exact through the raw RFC822 encoding")
    func bodyWithArabicAndEmojiRoundTripsByteExact() {
        let body = "مرحبا! 👋 هذا اختبار مع نص عربي وإيموجي 🎉📧\nSecond line: café — done."
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "ok", bodyText: body))
        // Byte-exact apart from the CRLF the MIME spec requires of a text part.
        #expect(mime.plain == MIMEHeader.normalizeCRLF(body))
        #expect(mime.html.contains("مرحبا"))
        #expect(mime.html.contains("🎉📧"))
    }

    // MARK: multipart/alternative structure

    @Test("send's raw RFC822 is a multipart/alternative message with a boundary absent from both parts")
    func multipartStructureHasSafeBoundary() {
        let message = OutgoingMessage(
            to: [MailAddress(email: "b@example.com")],
            subject: "Plans", bodyText: "**bold** plan with a [link](https://example.com)")
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""

        #expect(decoded.contains("Content-Type: multipart/alternative; boundary=\""))
        #expect(decoded.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(decoded.contains("Content-Type: text/html; charset=UTF-8"))

        guard let boundaryRange = decoded.range(of: "boundary=\"") else {
            Issue.record("no boundary found")
            return
        }
        let afterQuote = decoded[boundaryRange.upperBound...]
        guard let endQuote = afterQuote.firstIndex(of: "\"") else {
            Issue.record("boundary not closed")
            return
        }
        let boundary = String(afterQuote[afterQuote.startIndex..<endQuote])
        #expect(!boundary.isEmpty)

        // The boundary line itself is excluded from this check — only the
        // PART BODIES must never contain it.
        let parts = decoded.components(separatedBy: "--\(boundary)")
        for part in parts.dropFirst().dropLast() {
            #expect(part.contains(boundary) == false)
        }

        // CRLF throughout, not bare LF. This used to read
        // `#expect(decoded.contains("\r\n"))` — true of any message that has
        // headers at all, so it could not fail. What it claims is that NO line
        // ending is a bare LF, which is what is asserted now.
        #expect(decoded.contains("\r\n"))
        #expect(decoded.components(separatedBy: "\r\n").joined().contains("\n") == false)
        #expect(decoded.components(separatedBy: "\r\n").joined().contains("\r") == false)
    }

    // MARK: markdown -> HTML on send

    @Test("markdown bold, italic, inline code, a link, and a bullet list all appear in the HTML part")
    func markdownFeaturesAppearInHTMLPart() {
        let markdown = """
            Hello **bold** and *italic* and `code` and [a link](https://example.com).

            - first item
            - second item
            """
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "s", bodyText: markdown))

        #expect(mime.html.contains("<strong>bold</strong>"))
        #expect(mime.html.contains("<em>italic</em>"))
        #expect(mime.html.contains("<code>code</code>"))
        #expect(mime.html.contains("<a href=\"https://example.com\">a link</a>"))
        #expect(mime.html.contains("<ul>"))
        #expect(mime.html.contains("<li>first item</li>"))
        #expect(mime.html.contains("<li>second item</li>"))

        // The plain part is kept as typed (CRLF-normalized) — the fallback must
        // stay readable, not itself be HTML.
        #expect(mime.plain == MIMEHeader.normalizeCRLF(markdown))
    }

    @Test("a body containing <script> is escaped in the HTML part rather than injected")
    func scriptTagIsEscapedNotInjected() {
        let malicious = "Look at this: <script>alert('x')</script> & also <b>bold</b>."
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "s", bodyText: malicious))

        // The HTML part must never contain a live <script> tag.
        #expect(mime.html.isEmpty == false)
        #expect(mime.html.contains("<script>") == false)
        #expect(mime.html.contains("&lt;script&gt;"))
        #expect(mime.html.contains("&amp;"))

        // The plain part keeps the literal text unescaped, exactly as typed.
        #expect(mime.plain.contains(malicious))
    }

    // MARK: header injection (CRLF) — every field, at the point of emission

    /// `RFC2047.encode` returns pure-ASCII input unchanged, so nothing used to
    /// validate an ASCII header value. Reply and forward subjects derive from
    /// `thread.subject` and `In-Reply-To` is a raw remote `Message-ID`: both
    /// come from RECEIVED mail, so a crafted incoming message could inject
    /// headers into the user's own reply. One test per header field.
    @Test("a CRLF in the subject cannot inject a header")
    func subjectCannotInjectHeader() {
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")],
                subject: "hello\r\nBcc: attacker@evil.com", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
        #expect(
            mime.header("Subject")?.contains("Bcc") == true,
            "the text should survive as subject content, just not as a header")
    }

    @Test("a CRLF in a recipient address cannot inject a header")
    func toAddressCannotInjectHeader() {
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com\r\nBcc: attacker@evil.com")],
                subject: "s", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
    }

    @Test("a CRLF in a display name cannot inject a header")
    func displayNameCannotInjectHeader() {
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com", name: "Bea\r\nBcc: attacker@evil.com")],
                subject: "s", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
    }

    @Test("a CRLF in a Cc address cannot inject a header")
    func ccCannotInjectHeader() {
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")],
                cc: [MailAddress(email: "c@example.com\r\nBcc: attacker@evil.com")],
                subject: "s", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
    }

    @Test("a CRLF in a remote Message-ID cannot inject a header via In-Reply-To or References")
    func inReplyToCannotInjectHeader() {
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "s", bodyText: "body",
                inReplyToMessageID: "<a@b>\r\nBcc: attacker@evil.com"))
        #expect(mime.headerNames.contains("Bcc") == false)
        #expect(mime.header("In-Reply-To")?.contains("\r") == false)
        #expect(mime.header("References")?.contains("\r") == false)
    }

    @Test("no header line in a fully hostile message contains a bare CR or LF")
    func noHeaderLineContainsBareLineBreak() {
        let hostile = "x\r\nBcc: attacker@evil.com\rand\nmore"
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com", name: hostile)],
                cc: [MailAddress(email: "c@example.com", name: hostile)],
                subject: hostile, bodyText: "body", inReplyToMessageID: hostile))
        #expect(
            mime.headerNames.sorted()
                == ["Content-Type", "Cc", "In-Reply-To", "MIME-Version", "References", "Subject", "To"]
                .sorted())
    }

    // MARK: Content-Transfer-Encoding and line length

    @Test("both parts declare and use base64, so no line exceeds RFC 5322's 998-octet limit")
    func partsAreBase64AndLinesAreShort() {
        // A single typed paragraph well over the limit (verified at 1300 bytes
        // in the review that found this).
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 30)
        #expect(long.utf8.count > 998)
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "s", bodyText: long))

        #expect(mime.raw.contains("Content-Transfer-Encoding: base64"))
        for line in mime.raw.components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 998, "line of \(line.utf8.count) octets exceeds RFC 5322")
        }
        // And it is genuinely base64d, not merely declared so.
        #expect(mime.raw.contains(long) == false)
        #expect(mime.plain == long)
    }

    // MARK: signature and reply-quote in the HTML part

    /// The coverage whose absence let the sigdash defect ship. `-- ` is a valid
    /// setext-h2 underline, so feeding `body + "\n-- \n" + signature` to the
    /// Markdown parser turned the body's last line into a heading, which was
    /// then dropped, and deleted the separator recipients' clients use to trim
    /// a signature.
    @Test("a signed body keeps every line and an explicit signature separator in BOTH parts")
    func signedBodySurvivesInBothParts() {
        let composed =
            "Hi Bea,\n\nThanks for the update."
            + Signature.sigdash + "Ahmed\nAinkrad"
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "s", bodyText: composed))

        // Plain part: exactly body + "\n-- \n" + signature, CRLF-normalized.
        #expect(mime.plain == MIMEHeader.normalizeCRLF(composed))
        #expect(mime.plain.contains("\r\n-- \r\n"))

        // HTML part: nothing lost, separator explicit, no invented heading.
        #expect(mime.html.contains("<p>Hi Bea,</p>"))
        #expect(mime.html.contains("<p>Thanks for the update.</p>"))
        #expect(mime.html.contains("-- <br>"))
        #expect(mime.html.contains("Ahmed<br>Ainkrad"))
        #expect(mime.html.contains("<h2>") == false)
    }

    /// The coverage whose absence let the block-quote defect ship: the HTML
    /// part of every reply presented the original author's words as the
    /// sender's own.
    @Test("a reply's quoted text is a <blockquote> in the HTML part, with the reply outside it")
    func replyQuoteIsQuotedInHTMLPart() {
        let quoted = ReplyComposer.quoteBody(
            mode: .reply,
            message: MailMessage(
                id: "m1", threadID: "t1", rfc822MessageID: "<a@b>",
                from: MailAddress(email: "bea@example.com", name: "Bea"),
                subject: "hello",
                date: Date(timeIntervalSince1970: 1_700_000_000)),
            bodyText: "quoted line\n-- \nأحمد")
        let mime = DecodedRFC822(
            OutgoingMessage(
                to: [MailAddress(email: "b@example.com")], subject: "Re: hello",
                bodyText: "أهلا This is a reply." + quoted))

        #expect(mime.html.contains("<blockquote>"))
        // The regression: everything flattened into two paragraphs with the
        // quote markers gone — `<p>أهلا This is a reply.</p><p>quoted line -- أحمد</p>`.
        #expect(mime.html.contains("<p>quoted line -- أحمد</p>") == false)
        let quoteStart = mime.html.range(of: "<blockquote>")
        #expect(quoteStart != nil)
        if let quoteStart {
            let beforeQuote = String(mime.html[mime.html.startIndex..<quoteStart.lowerBound])
            #expect(beforeQuote.contains("This is a reply."))
            #expect(beforeQuote.contains("quoted line") == false)
        }
        #expect(mime.html.contains("quoted line"))
        // The plain part still carries the `>` markers verbatim.
        #expect(mime.plain.contains("> quoted line"))
    }
}
