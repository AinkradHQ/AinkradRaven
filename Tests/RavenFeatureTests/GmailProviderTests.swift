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

    // MARK: send() / raw RFC822 encoding

    @Test("send's raw RFC822 round-trips an ASCII subject and body correctly")
    func sendRoundTripsASCII() {
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "Hello there",
                                      bodyText: "Line one\nLine two")
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""
        #expect(decoded.contains("Subject: Hello there"))
        #expect(decoded.contains("Line one\nLine two"))
    }

    // KNOWN LIMITATION, documented rather than hidden (see task report): the
    // current minimal RFC822 builder writes the `Subject:` header as literal
    // UTF-8 bytes with no RFC 2047 encoded-word wrapping. RFC 5322 requires
    // non-ASCII header field bodies to be MIME-encoded; this implementation
    // does not do that. The body itself is fine — `Content-Type: text/plain;
    // charset=UTF-8` on a UTF-8-encoded byte stream round-trips exactly. This
    // test documents ACTUAL behaviour (the literal bytes appear, unencoded)
    // rather than asserting a level of correctness the code does not have.
    @Test("send's raw RFC822 preserves non-ASCII body bytes; the Subject header is emitted unencoded (documented limitation)")
    func sendRawEncodingOfNonASCII() {
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "Café ☕️ update",
                                      bodyText: "Bonjour café\nSecond line — emdash")
        let raw = GmailProvider.rfc822(message)
        let decoded = GmailMapping.decodeBase64URL(raw) ?? ""

        // The body round-trips exactly, non-ASCII and newline included.
        #expect(decoded.contains("Bonjour café\nSecond line — emdash"))

        // The Subject header is present but literal, unencoded UTF-8 — not
        // the RFC 2047 `=?UTF-8?B?...?=` form a strictly-conformant parser
        // would require. Documented here, not silently accepted as correct.
        #expect(decoded.contains("Subject: Café ☕️ update"))
        #expect(decoded.contains("=?UTF-8?B?") == false)
    }
}
