import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Exercises `GraphProvider` end to end against recorded fixture bytes and
/// synthetic HTTP responses, via `StubURLProtocol` — no live network call.
///
/// **Verified against fixtures only.** There is no Azure app registration, so
/// nothing here has met a real Graph endpoint; live verification is Task 24's.
@Suite("Graph provider")
@MainActor
struct GraphProviderTests {
    private func fixture(_ name: String) throws -> Data { try graphFixture(name) }
    private func makeProvider() -> GraphProvider { makeGraphProvider() }
    private func bounded<T: Sendable>(_ label: String,
                                      sourceLocation: SourceLocation = #_sourceLocation,
                                      _ body: @MainActor @escaping () async throws -> T)
        async throws -> T {
        try await graphBounded(label, sourceLocation: sourceLocation, body)
    }

    // MARK: Requests carry the access token

    @Test("every read sends the bearer token and never the refresh token")
    func readsAreAuthorized() async throws {
        let seen = SeenRequests()
        let messages = try fixture("graph-messages")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], messages)
        }
        defer { StubURLProtocol.handler = nil }

        _ = try await bounded("fetchThreads") {
            try await self.makeProvider().fetchThreads(since: Date(timeIntervalSince1970: 0),
                                                       pageToken: nil)
        }
        let headers = seen.all.map(\.authorization)
        #expect(headers == ["Bearer access-token"])
    }

    // MARK: fetchThreads / paging

    @Test("fetchThreads groups a recorded page into conversations and carries the nextLink")
    func fetchThreadsGroupsAndPages() async throws {
        let messages = try fixture("graph-messages")
        StubURLProtocol.handler = { _ in (200, [:], messages) }
        defer { StubURLProtocol.handler = nil }

        let page = try await bounded("fetchThreads") {
            try await self.makeProvider().fetchThreads(since: Date(timeIntervalSince1970: 0),
                                                       pageToken: nil)
        }
        #expect(page.threads.map(\.id) == ["conv-1", "conv-2"])
        #expect(page.threads.map { $0.messages.count } == [2, 1])
        // `@odata.nextLink` becomes `ThreadPage.nextPageToken` — no protocol
        // change, and the value is Graph's opaque link, replayed verbatim.
        #expect(page.nextPageToken
                == "https://graph.microsoft.com/v1.0/me/messages?$skiptoken=PAGE-2")
    }

    /// A `@odata.nextLink` must be replayed EXACTLY, not rebuilt: the skip
    /// token is opaque and any reconstruction silently restarts the walk at
    /// page one, which loops forever over the first page.
    @Test("a page token is requested as the verbatim nextLink URL")
    func nextLinkIsReplayedVerbatim() async throws {
        let seen = SeenRequests()
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], Data(#"{"value":[]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let link = "https://graph.microsoft.com/v1.0/me/messages?$skiptoken=PAGE-2"
        let page = try await bounded("fetchThreads(page 2)") {
            try await self.makeProvider().fetchThreads(since: Date(timeIntervalSince1970: 0),
                                                       pageToken: link)
        }
        #expect(seen.all.map(\.url) == [link])
        #expect(page.threads.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    // MARK: fetchThread

    @Test("fetchThread asks for the conversation by id and returns it whole")
    func fetchThreadFiltersByConversation() async throws {
        let seen = SeenRequests()
        let messages = try fixture("graph-messages")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], messages)
        }
        defer { StubURLProtocol.handler = nil }

        let thread = try await bounded("fetchThread") {
            try await self.makeProvider().fetchThread(id: "conv-1")
        }
        #expect(thread.id == "conv-1")
        #expect(thread.messages.map(\.id) == ["m3", "m1"])
        let url = try #require(seen.all.first?.url.removingPercentEncoding)
        #expect(url.contains("$filter=conversationId eq 'conv-1'"))
    }

    /// An id that matches nothing is `unknownThread`, never an empty thread:
    /// an empty `MailThread` upserted over a stored one blanks the conversation.
    @Test("a conversation with no messages is unknownThread, not an empty thread")
    func emptyConversationIsUnknownThread() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data(#"{"value":[]}"#.utf8)) }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        await #expect(throws: MailError.unknownThread("conv-gone")) {
            try await self.bounded("fetchThread(empty)") {
                _ = try await provider.fetchThread(id: "conv-gone")
            }
        }
    }

    @Test("a 404 on fetchThread maps to unknownThread, not providerFailed")
    func notFoundMapsToUnknownThread() async throws {
        StubURLProtocol.handler = { _ in
            (404, [:], Data(#"{"error":{"code":"ItemNotFound"}}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        await #expect(throws: MailError.unknownThread("conv-gone")) {
            try await self.bounded("fetchThread(404)") {
                _ = try await provider.fetchThread(id: "conv-gone")
            }
        }
    }


    // MARK: Rate limiting

    @Test("a 429 with Retry-After maps to MailError.rateLimited honouring the header")
    func rateLimitedHonoursRetryAfter() async throws {
        StubURLProtocol.handler = { _ in (429, ["Retry-After": "17"], Data()) }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        await #expect(throws: MailError.rateLimited(retryAfter: 17)) {
            try await self.bounded("fetchLabels(429)") { _ = try await provider.fetchLabels() }
        }
    }

    @Test("a 429 with no Retry-After falls back to a sane default rather than failing to decode")
    func rateLimitedFallsBackWithoutHeader() async throws {
        StubURLProtocol.handler = { _ in (429, [:], Data()) }
        defer { StubURLProtocol.handler = nil }

        do {
            let provider = makeProvider()
            _ = try await bounded("fetchLabels(429 no header)") {
                try await provider.fetchLabels()
            }
            Issue.record("expected rateLimited")
        } catch let MailError.rateLimited(retryAfter) {
            #expect(retryAfter > 0)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    /// `SyncEngine` persists `String(describing:)` of a thrown error into
    /// `MailAccount.lastError`, which is written to a document — so a Graph
    /// error body, which echoes the request, must never reach it.
    @Test("providerFailed carries a fixed phrase and never the response body")
    func providerFailedMessageIsShort() async throws {
        StubURLProtocol.handler = { _ in
            (400, [:], Data("""
            {"error":{"code":"BadRequest","message":"Invalid filter clause: a@example.test token=abc123"}}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            let provider = makeProvider()
            _ = try await bounded("fetchLabels(400)") { try await provider.fetchLabels() }
            Issue.record("expected providerFailed")
        } catch let MailError.providerFailed(status, message) {
            #expect(status == 400)
            #expect(message.contains("abc123") == false)
            #expect(message.contains("a@example.test") == false)
            #expect(message.contains("Invalid filter") == false)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: Bodies, folders, attachments, search

    @Test("fetchBody maps a recorded message end to end")
    func fetchBodyMapsRecordedMessage() async throws {
        let seen = SeenRequests()
        let message = try fixture("graph-message")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], message)
        }
        defer { StubURLProtocol.handler = nil }

        let body = try await bounded("fetchBody") {
            try await self.makeProvider().fetchBody(messageID: "m1")
        }
        #expect(body.messageID == "m1")
        #expect(body.plainText.contains("Reply 1"))
        #expect(body.plainText.contains("<") == false)
        let html = try #require(body.html)
        #expect(html.contains("<blockquote>"))
        // `uniqueBody` is not in Graph's default projection — it has to be
        // asked for, or every body silently falls back to the full one.
        let url = try #require(seen.all.first?.url.removingPercentEncoding)
        #expect(url.contains("uniqueBody"))
        #expect(url.contains("/me/messages/m1"))
    }

    @Test("fetchLabels maps recorded folders, keyed on wellKnownName")
    func fetchLabelsMapsFolders() async throws {
        let folders = try fixture("graph-folders")
        StubURLProtocol.handler = { _ in (200, [:], folders) }
        defer { StubURLProtocol.handler = nil }

        let labels = try await bounded("fetchLabels") {
            try await self.makeProvider().fetchLabels()
        }
        #expect(labels.map(\.id) == ["folder-a-id", "folder-b-id", "folder-c-id"])
        #expect(labels.map(\.kind) == [.user, .system, .user])
    }

    /// Graph sends STANDARD base64. The fixture's payload is deliberately
    /// binary and deliberately encodes with `+`, `/` and `=` all present, so
    /// an alphabet or padding mistake changes the BYTES rather than throwing —
    /// text-only fixture bytes would decode "close enough" to pass.
    ///
    /// The expected bytes are written out literally rather than re-encoded
    /// from the same string the provider decoded, which would be the
    /// "assertion computed by calling the code it checks" shape.
    @Test("fetchAttachment decodes standard base64 byte-exactly")
    func fetchAttachmentDecodesStandardBase64() async throws {
        let attachment = try fixture("graph-attachments")
        StubURLProtocol.handler = { _ in (200, [:], attachment) }
        defer { StubURLProtocol.handler = nil }

        let data = try await bounded("fetchAttachment") {
            try await self.makeProvider().fetchAttachment(messageID: "m1", attachmentID: "att-1")
        }
        #expect(Array(data) == [0xFB, 0xEF, 0xBE, 0x00, 0x01, 0x02, 0xFF, 0xFE])
        #expect(data.count == 8)
    }

    @Test("an attachment with no contentBytes is a typed decoding failure")
    func attachmentWithoutBytesFails() async throws {
        StubURLProtocol.handler = { _ in
            (200, [:], Data(#"{"id":"att-2","name":"Attachment 2.bin"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        await #expect(throws: MailError.decodingFailed("attachment att-2")) {
            try await self.bounded("fetchAttachment(no bytes)") {
                _ = try await provider.fetchAttachment(messageID: "m1", attachmentID: "att-2")
            }
        }
    }

    @Test("searchThreads passes the query through as $search and groups the hits")
    func searchPassesQueryThrough() async throws {
        let seen = SeenRequests()
        let messages = try fixture("graph-messages")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], messages)
        }
        defer { StubURLProtocol.handler = nil }

        let threads = try await bounded("searchThreads") {
            try await self.makeProvider().searchThreads(query: "from:a@example.test", limit: 10)
        }
        #expect(threads.map(\.id) == ["conv-1", "conv-2"])
        let url = try #require(seen.all.first?.url.removingPercentEncoding)
        #expect(url.contains("$search=\"from:a@example.test\""))
    }

    /// A wire value reaching a query language gets its delimiters escaped —
    /// the same rule `fetchThread` applies to the OData `'`. A subject like
    /// `Re: the "final" draft` otherwise closes the KQL string early and the
    /// server rejects the request.
    ///
    /// Asserted on the emitted parameter, not on the response: the stub answers
    /// the same bytes either way, so only the request can tell the difference.
    @Test("a query containing the KQL delimiter is escaped, not left to break the search")
    func searchEscapesTheQuoteDelimiter() async throws {
        let seen = SeenRequests()
        let messages = try fixture("graph-messages")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], messages)
        }
        defer { StubURLProtocol.handler = nil }

        _ = try await bounded("searchThreads(quoted)") {
            try await self.makeProvider().searchThreads(query: #"the "final" draft"#, limit: 5)
        }
        let url = try #require(seen.all.first?.url.removingPercentEncoding)
        // The whole parameter, so the escaping is pinned exactly: one opening
        // quote, one closing quote, and the inner pair escaped.
        #expect(url.contains(#"$search="the \"final\" draft""#))
        // The unescaped form — three bare quotes, the malformed request — is
        // what this replaces, and it must be gone.
        #expect(url.contains(#"$search="the "final" draft""#) == false)
    }

    /// A backslash must be escaped BEFORE the quote, or its own escape
    /// character gets re-escaped and `\"` turns back into a terminator.
    @Test("a backslash in a query is escaped before the quote, not after")
    func searchEscapesBackslashFirst() async throws {
        let seen = SeenRequests()
        let messages = try fixture("graph-messages")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], messages)
        }
        defer { StubURLProtocol.handler = nil }

        _ = try await bounded("searchThreads(backslash)") {
            try await self.makeProvider().searchThreads(query: #"a\b"c"#, limit: 5)
        }
        let url = try #require(seen.all.first?.url.removingPercentEncoding)
        #expect(url.contains(#"$search="a\\b\"c""#))
    }

    @Test("searchThreads never returns more threads than the limit")
    func searchRespectsLimit() async throws {
        let messages = try fixture("graph-messages")
        StubURLProtocol.handler = { _ in (200, [:], messages) }
        defer { StubURLProtocol.handler = nil }

        let threads = try await bounded("searchThreads(limit 1)") {
            try await self.makeProvider().searchThreads(query: "anything", limit: 1)
        }
        #expect(threads.count == 1)
        #expect(threads.first?.id == "conv-1")
    }

    // MARK: Writes are Task 20's

    /// Read paths only. A refusal, never a fabricated message id: at-most-once
    /// send is built on a RECORDED success, so a stub return here would record
    /// a send that never happened.
    @Test("send and applyLabels are refused while Graph is read-only")
    func writesAreRefused() async throws {
        let provider = makeProvider()
        #expect(provider.capabilities == .readOnly)
        await #expect(throws: MailError.readOnlyAccount("a1")) {
            try await self.bounded("send") {
                _ = try await provider.send(
                    OutgoingMessage(to: [MailAddress(email: "b@example.test")],
                                    subject: "Subject 1", bodyText: "body"))
            }
        }
        await #expect(throws: MailError.readOnlyAccount("a1")) {
            try await self.bounded("applyLabels") {
                try await provider.applyLabels(LabelMutation(threadIDs: ["conv-1"], add: ["x"]))
            }
        }
    }
}
