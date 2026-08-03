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
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "Hello there",
                                      bodyText: "Line one\nLine two")
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""
        #expect(decoded.contains("Subject: Hello there"))
        #expect(decoded.contains("Line one\nLine two"))
        // Encoding an ASCII-only subject is legal but ugly in some clients —
        // it must stay literal.
        #expect(decoded.contains("=?UTF-8?B?") == false)
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
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "ok", bodyText: body)
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""
        #expect(decoded.contains(body))
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

        // CRLF throughout, not bare LF.
        #expect(decoded.contains("\r\n"))
    }

    // MARK: markdown -> HTML on send

    @Test("markdown bold, italic, inline code, a link, and a bullet list all appear in the HTML part")
    func markdownFeaturesAppearInHTMLPart() {
        let markdown = """
        Hello **bold** and *italic* and `code` and [a link](https://example.com).

        - first item
        - second item
        """
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "s", bodyText: markdown)
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""

        #expect(decoded.contains("<strong>bold</strong>"))
        #expect(decoded.contains("<em>italic</em>"))
        #expect(decoded.contains("<code>code</code>"))
        #expect(decoded.contains("<a href=\"https://example.com\">a link</a>"))
        #expect(decoded.contains("<ul>"))
        #expect(decoded.contains("<li>first item</li>"))
        #expect(decoded.contains("<li>second item</li>"))

        // The plain part is kept exactly as typed — the fallback must stay
        // readable, not itself be HTML.
        #expect(decoded.contains(markdown))
    }

    @Test("a body containing <script> is escaped in the HTML part rather than injected")
    func scriptTagIsEscapedNotInjected() {
        let malicious = "Look at this: <script>alert('x')</script> & also <b>bold</b>."
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "s", bodyText: malicious)
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""

        // The HTML part must never contain a live <script> tag.
        guard let htmlPartRange = decoded.range(of: "Content-Type: text/html") else {
            Issue.record("no HTML part found")
            return
        }
        let htmlPart = decoded[htmlPartRange.lowerBound...]
        #expect(htmlPart.contains("<script>") == false)
        #expect(htmlPart.contains("&lt;script&gt;"))
        #expect(htmlPart.contains("&amp;"))

        // The plain part keeps the literal text unescaped, exactly as typed.
        #expect(decoded.contains(malicious))
    }
}
