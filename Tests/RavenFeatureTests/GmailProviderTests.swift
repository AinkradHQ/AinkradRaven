import Testing
import Foundation
@testable import RavenFeature
import AinkradAppKit

/// Exercises `GmailProvider` end to end against recorded fixture bytes and
/// synthetic HTTP responses, via `StubURLProtocol` — no live network call.
@Suite("Gmail provider")
@MainActor
struct GmailProviderTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func makeProvider() -> GmailProvider {
        let secrets = InMemorySecretStore()
        secrets.setSecret("refresh-token", forKey: "refresh-a1")
        let auth = GmailAuth(secrets: secrets, clientID: "cid", clientSecret: "csecret") { _ in
            ("access-token", 3600)
        }
        return GmailProvider(accountID: "a1", auth: auth, session: StubURLProtocol.makeSession())
    }

    // MARK: fetchThread 404 -> unknownThread (carry-over from Task 8's review)

    @Test("a 404 on fetchThread maps to MailError.unknownThread, not providerFailed")
    func notFoundThreadMapsToUnknownThread() async throws {
        let provider = makeProvider()
        StubURLProtocol.handler = { _ in
            (404, [:], Data("{\"error\":{\"message\":\"Requested entity was not found.\"}}".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        await #expect(throws: MailError.unknownThread("gone-thread-id")) {
            _ = try await provider.fetchThread(id: "gone-thread-id")
        }
    }

    // MARK: rate limiting

    @Test("a 429 with Retry-After maps to MailError.rateLimited honouring the header")
    func rateLimitedHonoursRetryAfter() async throws {
        let provider = makeProvider()
        StubURLProtocol.handler = { _ in (429, ["Retry-After": "17"], Data()) }
        defer { StubURLProtocol.handler = nil }

        await #expect(throws: MailError.rateLimited(retryAfter: 17)) {
            _ = try await provider.fetchLabels()
        }
    }

    @Test("a 429 with no Retry-After falls back to a sane default rather than failing to decode")
    func rateLimitedFallsBackWithoutRetryAfterHeader() async throws {
        let provider = makeProvider()
        StubURLProtocol.handler = { _ in (429, [:], Data()) }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await provider.fetchLabels()
            Issue.record("expected rateLimited")
        } catch let MailError.rateLimited(retryAfter) {
            #expect(retryAfter > 0)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: providerFailed never carries the raw response body

    @Test("a non-2xx, non-404, non-429 status maps to providerFailed with a short, non-sensitive message")
    func providerFailedMessageIsShort() async throws {
        let provider = makeProvider()
        // A body that echoes request context, the way a real Gmail error can.
        StubURLProtocol.handler = { _ in
            (400, [:], Data("{\"error\":{\"message\":\"Invalid query: q=after:1785693524 secret=abc123\"}}".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await provider.fetchLabels()
            Issue.record("expected providerFailed")
        } catch let MailError.providerFailed(status, message) {
            #expect(status == 400)
            #expect(message.contains("secret=abc123") == false)
            #expect(message.contains("q=after") == false)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: fetchDelta with an absent `history` key

    @Test("fetchDelta on a history response with no history key returns an empty delta and advances the cursor")
    func fetchDeltaWithNoHistoryKeyIsEmptyButAdvancesCursor() async throws {
        let provider = makeProvider()
        let historyFixture = try fixture("history")
        StubURLProtocol.handler = { _ in (200, [:], historyFixture) }
        defer { StubURLProtocol.handler = nil }

        let delta = try await provider.fetchDelta(cursor: "1")

        #expect(delta.changedThreadIDs.isEmpty)
        #expect(delta.removedThreadIDs.isEmpty)
        #expect(delta.newCursor == "2171944")   // historyId from the real fixture
        #expect(delta.newCursor != "1")
    }

    // MARK: fetchThread against a real recorded thread

    @Test("fetchThread maps a recorded thread response end to end")
    func fetchThreadMapsRecordedResponse() async throws {
        let provider = makeProvider()
        let threadFixture = try fixture("thread-0")
        StubURLProtocol.handler = { _ in (200, [:], threadFixture) }
        defer { StubURLProtocol.handler = nil }

        let thread = try await provider.fetchThread(id: "19fc3a0d1591338e")
        #expect(thread.id == "19fc3a0d1591338e")
        #expect(thread.accountID == "a1")
        #expect(thread.messages.isEmpty == false)
    }

    // MARK: fetchThreads must not silently drop mail

    /// Backfill seeds the sync cursor on success, so a thread quietly dropped
    /// here is filed behind the cursor and never re-delivered — permanent,
    /// invisible loss. A transient failure must therefore surface, not be
    /// swallowed by `try?`.
    @Test("a transient failure on one thread fails the whole page instead of dropping it")
    func transientThreadFailureDuringListingIsNotSwallowed() async throws {
        let provider = makeProvider()
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/threads") {
                return (200, [:], Data(#"{"threads":[{"id":"t1"},{"id":"t2"}]}"#.utf8))
            }
            return (500, [:], Data(#"{"error":{"message":"backend error"}}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        await #expect(throws: MailError.self) {
            _ = try await provider.fetchThreads(since: Date(timeIntervalSince1970: 0),
                                                pageToken: nil)
        }
    }

    @Test("a thread that is genuinely gone (404) is skipped, and the rest of the page still loads")
    func vanishedThreadDuringListingIsSkipped() async throws {
        let provider = makeProvider()
        let threadFixture = try fixture("thread-0")
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/threads") {
                return (200, [:],
                        Data(#"{"threads":[{"id":"gone"},{"id":"19fc3a0d1591338e"}]}"#.utf8))
            }
            if path.hasSuffix("/threads/gone") {
                return (404, [:], Data(#"{"error":{"message":"not found"}}"#.utf8))
            }
            return (200, [:], threadFixture)
        }
        defer { StubURLProtocol.handler = nil }

        let page = try await provider.fetchThreads(since: Date(timeIntervalSince1970: 0),
                                                   pageToken: nil)
        #expect(page.threads.map(\.id) == ["19fc3a0d1591338e"])
    }

    // MARK: fetchThreads concurrency

    /// `fetchThreads` fetches per-thread bodies with bounded concurrency
    /// (Task 9/post-launch fix), which previously issued one sequential
    /// round trip per thread. Concurrency must not scramble the page's
    /// order: callers depend on `page.threads` matching the listing order
    /// from Gmail, not whichever request happens to answer first.
    @Test("fetchThreads returns threads in listing order even though they are fetched concurrently")
    func fetchThreadsPreservesOrderUnderConcurrency() async throws {
        let provider = makeProvider()
        // More ids than the concurrency cap, so at least one batch has to
        // schedule a second wave — if slot placement used completion order
        // instead of the original index, this would be the case most likely
        // to show it.
        let ids = (0..<9).map { "t\($0)" }
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/threads") {
                let refs = ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
                return (200, [:], Data("{\"threads\":[\(refs)]}".utf8))
            }
            let id = String(path.split(separator: "/").last ?? "")
            let thread = "{\"id\":\"\(id)\",\"historyId\":\"1\",\"messages\":[" +
                "{\"id\":\"\(id)\",\"threadId\":\"\(id)\",\"labelIds\":[]," +
                "\"snippet\":\"\",\"payload\":{\"headers\":[]}}]}"
            return (200, [:], Data(thread.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let page = try await provider.fetchThreads(since: Date(timeIntervalSince1970: 0),
                                                    pageToken: nil)
        #expect(page.threads.map(\.id) == ids)
    }

    /// The skip-on-404 semantics (`vanishedThreadDuringListingIsSkipped`
    /// above) must keep holding once fetches run concurrently: a vanished
    /// thread in the middle of a larger page is dropped, and every other
    /// thread still comes back in order.
    @Test("a vanished thread in the middle of a larger page is skipped without disturbing the order of the rest")
    func vanishedThreadAmongManyIsSkippedInOrder() async throws {
        let provider = makeProvider()
        let ids = (0..<8).map { "t\($0)" }
        let goneID = "t4"
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/threads") {
                let refs = ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
                return (200, [:], Data("{\"threads\":[\(refs)]}".utf8))
            }
            let id = String(path.split(separator: "/").last ?? "")
            if id == goneID {
                return (404, [:], Data(#"{"error":{"message":"not found"}}"#.utf8))
            }
            let thread = "{\"id\":\"\(id)\",\"historyId\":\"1\",\"messages\":[" +
                "{\"id\":\"\(id)\",\"threadId\":\"\(id)\",\"labelIds\":[]," +
                "\"snippet\":\"\",\"payload\":{\"headers\":[]}}]}"
            return (200, [:], Data(thread.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let page = try await provider.fetchThreads(since: Date(timeIntervalSince1970: 0),
                                                    pageToken: nil)
        #expect(page.threads.map(\.id) == ids.filter { $0 != goneID })
    }

    // MARK: send() / raw RFC822 encoding

    @Test("send's raw RFC822 round-trips an ASCII subject and body correctly, and leaves the subject unencoded")
    func sendRoundTripsASCII() {
        let mime = DecodedRFC822(OutgoingMessage(
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
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com")], subject: "s",
            bodyText: "Line one\nLine two\rLine three\r\nLine four"))

        let scalars = Array(mime.raw.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\n" {
                #expect(index > 0 && scalars[index - 1] == "\r",
                        "bare LF at \(index)")
            }
            if scalar == "\r" {
                #expect(index + 1 < scalars.count && scalars[index + 1] == "\n",
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
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
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
    func longNonASCIISubjectFoldsWithoutSplittingUTF8() {
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
            let base64 = word
                .replacingOccurrences(of: "=?UTF-8?B?", with: "")
                .replacingOccurrences(of: "?=", with: "")
            let data = try! #require(Data(base64Encoded: base64))
            #expect(String(data: data, encoding: .utf8) != nil,
                    "a chunk that isn't valid UTF-8 on its own means a scalar was split")
        }

        #expect(RFC2047.decode(encoded) == subject)
    }

    // MARK: BODY round-trip (Arabic + emoji, byte-exact)

    @Test("a body containing Arabic and emoji round-trips byte-exact through the raw RFC822 encoding")
    func bodyWithArabicAndEmojiRoundTripsByteExact() {
        let body = "مرحبا! 👋 هذا اختبار مع نص عربي وإيموجي 🎉📧\nSecond line: café — done."
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com")], subject: "ok", bodyText: body))
        // Byte-exact apart from the CRLF the MIME spec requires of a text part.
        #expect(mime.plain == MIMEHeader.normalizeCRLF(body))
        #expect(mime.html.contains("مرحبا"))
        #expect(mime.html.contains("🎉📧"))
    }

    // MARK: multipart/alternative structure

    @Test("send's raw RFC822 is a multipart/alternative message with a boundary absent from both parts")
    func multipartStructureHasSafeBoundary() {
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
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
        let mime = DecodedRFC822(OutgoingMessage(
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
        let mime = DecodedRFC822(OutgoingMessage(
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
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com")],
            subject: "hello\r\nBcc: attacker@evil.com", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
        #expect(mime.header("Subject")?.contains("Bcc") == true,
                "the text should survive as subject content, just not as a header")
    }

    @Test("a CRLF in a recipient address cannot inject a header")
    func toAddressCannotInjectHeader() {
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com\r\nBcc: attacker@evil.com")],
            subject: "s", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
    }

    @Test("a CRLF in a display name cannot inject a header")
    func displayNameCannotInjectHeader() {
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com", name: "Bea\r\nBcc: attacker@evil.com")],
            subject: "s", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
    }

    @Test("a CRLF in a Cc address cannot inject a header")
    func ccCannotInjectHeader() {
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com")],
            cc: [MailAddress(email: "c@example.com\r\nBcc: attacker@evil.com")],
            subject: "s", bodyText: "body"))
        #expect(mime.headerNames.contains("Bcc") == false)
    }

    @Test("a CRLF in a remote Message-ID cannot inject a header via In-Reply-To or References")
    func inReplyToCannotInjectHeader() {
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com")], subject: "s", bodyText: "body",
            inReplyToMessageID: "<a@b>\r\nBcc: attacker@evil.com"))
        #expect(mime.headerNames.contains("Bcc") == false)
        #expect(mime.header("In-Reply-To")?.contains("\r") == false)
        #expect(mime.header("References")?.contains("\r") == false)
    }

    @Test("no header line in a fully hostile message contains a bare CR or LF")
    func noHeaderLineContainsBareLineBreak() {
        let hostile = "x\r\nBcc: attacker@evil.com\rand\nmore"
        let mime = DecodedRFC822(OutgoingMessage(
            to: [MailAddress(email: "b@example.com", name: hostile)],
            cc: [MailAddress(email: "c@example.com", name: hostile)],
            subject: hostile, bodyText: "body", inReplyToMessageID: hostile))
        #expect(mime.headerNames.sorted()
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
        let mime = DecodedRFC822(OutgoingMessage(
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
        let composed = "Hi Bea,\n\nThanks for the update."
            + Signature.sigdash + "Ahmed\nAinkrad"
        let mime = DecodedRFC822(OutgoingMessage(
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
            message: MailMessage(id: "m1", threadID: "t1", rfc822MessageID: "<a@b>",
                                 from: MailAddress(email: "bea@example.com", name: "Bea"),
                                 subject: "hello",
                                 date: Date(timeIntervalSince1970: 1_700_000_000)),
            bodyText: "quoted line\n-- \nأحمد")
        let mime = DecodedRFC822(OutgoingMessage(
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

/// A parsed view of what `GmailProvider.rfc822` actually emits: the header
/// block, and each `multipart/alternative` part with its
/// `Content-Transfer-Encoding` undone.
///
/// Tests used to assert against the base64url-decoded raw string directly.
/// That was how `#expect(decoded.contains("Line one\nLine two"))` came to
/// assert the bare-LF DEFECT as correct, and how "CRLF throughout, not bare
/// LF" was written as `#expect(decoded.contains("\r\n"))` — a tautology for
/// any message with headers. Decoding the parts properly is what makes those
/// assertions able to fail.
struct DecodedRFC822 {
    let raw: String
    let headerBlock: String
    let plain: String
    let html: String

    init(_ message: OutgoingMessage) {
        let rawText = GmailMapping.decodeBase64URL(GmailProvider.rfc822(message)) ?? ""
        raw = rawText

        let split = rawText.range(of: "\r\n\r\n")
        let headers = split.map { String(rawText[rawText.startIndex..<$0.lowerBound]) } ?? rawText
        headerBlock = headers
        let bodyBlock = split.map { String(rawText[$0.upperBound...]) } ?? ""

        let boundary = Self.boundary(inHeaderBlock: headers)
        let parts = boundary.isEmpty
            ? []
            : bodyBlock.components(separatedBy: "--\(boundary)").dropFirst().dropLast()
        var decodedParts: [String: String] = [:]
        for part in parts {
            guard let separator = part.range(of: "\r\n\r\n") else { continue }
            let partHeaders = String(part[part.startIndex..<separator.lowerBound])
            let content = String(part[separator.upperBound...])
            let key = partHeaders.contains("text/html") ? "html" : "plain"
            decodedParts[key] = Self.decodeContent(content, headers: partHeaders)
        }
        plain = decodedParts["plain"] ?? ""
        html = decodedParts["html"] ?? ""
    }

    /// Every header field NAME present, so an injected `Bcc:` is detectable as
    /// a header rather than merely as a substring somewhere in the message.
    /// Continuation lines (folding whitespace) are not header starts.
    var headerNames: [String] {
        headerBlock.components(separatedBy: "\r\n").compactMap { line in
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { return nil }
            return String(line[line.startIndex..<colon])
        }
    }

    /// One header's value, with any RFC 2047 encoded words decoded and folds
    /// unwrapped, so a test can assert on what a recipient would actually see.
    func header(_ name: String) -> String? {
        var value: String?
        for line in headerBlock.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if value != nil { value! += line }
                continue
            }
            if value != nil { break }
            if line.hasPrefix("\(name): ") {
                value = String(line.dropFirst(name.count + 2))
            }
        }
        return value.map(RFC2047.decode)
    }

    private static func boundary(inHeaderBlock headers: String) -> String {
        guard let start = headers.range(of: "boundary=\"") else { return "" }
        let rest = headers[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[rest.startIndex..<end])
    }

    private static func decodeContent(_ content: String, headers: String) -> String {
        guard headers.lowercased().contains("content-transfer-encoding: base64") else {
            return content
        }
        let joined = content
            .replacingOccurrences(of: "\r\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: joined) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
