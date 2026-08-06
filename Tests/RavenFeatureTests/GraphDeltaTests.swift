import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Graph's delta walk and the cursor it round-trips through
/// `MailAccount.syncCursor`, plus the 410-Gone recovery that hands the job
/// back to `SyncEngine.backfill()`. Split out of `GraphProviderTests` to keep
/// both files inside the 450-line limit.
///
/// **Verified against fixtures only** — there is no Azure app registration;
/// live verification is Task 24's.
@Suite("Graph delta")
@MainActor
struct GraphDeltaTests {
    private func fixture(_ name: String) throws -> Data { try graphFixture(name) }
    private func makeProvider() -> GraphProvider { makeGraphProvider() }
    private func bounded<T: Sendable>(_ label: String,
                                      sourceLocation: SourceLocation = #_sourceLocation,
                                      _ body: @MainActor @escaping () async throws -> T)
        async throws -> T {
        try await graphBounded(label, sourceLocation: sourceLocation, body)
    }

    // MARK: Delta

    @Test("fetchDelta sends the bare cursor as $deltatoken and returns the next bare token")
    func deltaRoundTripsThePlainToken() async throws {
        let seen = SeenRequests()
        let delta = try fixture("graph-delta")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], delta)
        }
        defer { StubURLProtocol.handler = nil }

        let result = try await bounded("fetchDelta") {
            try await self.makeProvider().fetchDelta(cursor: "DELTA-TOKEN-1")
        }
        // In: the plain string held in `MailAccount.syncCursor`.
        let url = try #require(seen.all.first?.url.removingPercentEncoding)
        #expect(url.contains("$deltatoken=DELTA-TOKEN-1"))
        #expect(url.contains("/me/mailFolders/inbox/messages/delta"))
        // Out: another plain string, extracted from `@odata.deltaLink`.
        #expect(result.newCursor == "DELTA-TOKEN-2")
        #expect(result.changedThreadIDs == ["conv-1", "conv-3"])
        #expect(result.removedThreadIDs == ["conv-2"])
    }

    /// The full round trip through the type that actually persists it: a
    /// cursor read out of `MailAccount.syncCursor` goes to Graph as a plain
    /// `$deltatoken`, and the token that comes back is stored as a plain
    /// string — no URL, no JSON envelope, no second document.
    @Test("the delta token round-trips through MailAccount.syncCursor as a plain string")
    func cursorRoundTripsThroughSyncCursor() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .graph,
                                          address: "a@example.test", displayName: "A",
                                          syncCursor: "DELTA-TOKEN-1", state: .ready))
        let seen = SeenRequests()
        let delta = try fixture("graph-delta")
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], delta)
        }
        defer { StubURLProtocol.handler = nil }

        let cursor = try #require(store.accounts().first?.syncCursor)
        let result = try await bounded("fetchDelta") {
            try await self.makeProvider().fetchDelta(cursor: cursor)
        }
        var account = try #require(store.accounts().first)
        account.syncCursor = result.newCursor
        try store.saveAccount(account)

        let stored = try #require(store.accounts().first?.syncCursor)
        #expect(stored == "DELTA-TOKEN-2")
        // Belt-and-braces: the equality above already fixes the value, so
        // these two cannot fail independently TODAY. They are kept because
        // they state the contract this boundary exists for — what lands in
        // `syncCursor` is a plain scalar, never a URL — and they are what
        // would fail first if the stored shape ever changed to a link.
        #expect(stored.hasPrefix("http") == false)
        #expect(stored.contains("$") == false)
    }

    /// The walk follows `@odata.nextLink` until a `@odata.deltaLink` arrives,
    /// accumulating entries from EVERY page. Stopping at the first page would
    /// pass any single-page test and lose mail on a real mailbox.
    @Test("a multi-page delta walk accumulates every page and ends on the deltaLink")
    func deltaFollowsNextLinks() async throws {
        let seen = SeenRequests()
        StubURLProtocol.handler = { request in
            seen.record(request)
            if request.url?.absoluteString.contains("PAGE-2") == true {
                return (200, [:], Data("""
                {"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=TOKEN-FINAL",
                 "value":[{"id":"m2","conversationId":"conv-2"}]}
                """.utf8))
            }
            return (200, [:], Data("""
            {"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=PAGE-2",
             "value":[{"id":"m1","conversationId":"conv-1"}]}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let result = try await bounded("fetchDelta(paged)") {
            try await self.makeProvider().fetchDelta(cursor: "TOKEN-0")
        }
        #expect(seen.all.count == 2)
        #expect(result.changedThreadIDs == ["conv-1", "conv-2"])
        #expect(result.newCursor == "TOKEN-FINAL")
    }

    /// **410 Gone on a stale delta token triggers a full backfill**, and it does
    /// so by plugging into M0's correction rather than growing a second
    /// recovery path: `SyncEngine.syncDelta` catches
    /// `providerFailed(status: 404|410)` from `fetchDelta` and calls
    /// `backfill()`. This drives the REAL `SyncEngine` over the REAL provider,
    /// so it fails if either half stops agreeing — asserting only the thrown
    /// error would leave "and the engine recovers" unobserved.
    @Test("a 410 on the delta endpoint makes SyncEngine fall back to a full backfill")
    func staleDeltaTokenTriggersBackfill() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .graph,
                                          address: "a@example.test", displayName: "A",
                                          syncCursor: "STALE-TOKEN", state: .ready))
        let messages = try fixture("graph-messages")
        let seen = SeenRequests()
        StubURLProtocol.handler = { request in
            seen.record(request)
            let url = request.url?.absoluteString.removingPercentEncoding ?? ""
            // 410 for the STALE token only. `$deltatoken=latest`, which
            // `backfill()` uses to re-seed the cursor at the end, is a fresh
            // request and succeeds — a stub that failed every delta call would
            // fail the recovery it is supposed to be proving.
            if url.contains("$deltatoken=STALE-TOKEN") {
                return (410, [:], Data(#"{"error":{"code":"SyncStateNotFound"}}"#.utf8))
            }
            if url.contains("$deltatoken=latest") {
                return (200, [:], Data("""
                {"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=FRESH-TOKEN",
                 "value":[]}
                """.utf8))
            }
            return (200, [:], messages)
        }
        defer { StubURLProtocol.handler = nil }

        let engine = SyncEngine(store: store, provider: makeProvider(), accountID: "a1")
        try await bounded("syncDelta after 410") { try await engine.syncDelta() }

        // The backfill actually ran and wrote the threads the delta could not.
        #expect(store.thread("conv-1") != nil)
        #expect(store.thread("conv-2") != nil)
        #expect(seen.all.contains { $0.url.contains("/delta") })
        #expect(seen.all.contains {
            ($0.url.removingPercentEncoding ?? "").contains("$filter=receivedDateTime")
        })
        // And the cursor advanced to the freshly-seeded token, so the next
        // sync is a delta again rather than another full backfill.
        #expect(store.accounts().first?.syncCursor == "FRESH-TOKEN")
    }

    /// The other side of that narrowness: a 500 is NOT evidence the cursor is
    /// bad, so it must not re-walk the mailbox. The cursor is held and the
    /// account is marked failed.
    @Test("a 500 on the delta endpoint holds the cursor instead of backfilling")
    func transientDeltaFailureHoldsTheCursor() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .graph,
                                          address: "a@example.test", displayName: "A",
                                          syncCursor: "GOOD-TOKEN", state: .ready))
        let seen = SeenRequests()
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (500, [:], Data(#"{"error":{"code":"ServiceUnavailable"}}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let engine = SyncEngine(store: store, provider: makeProvider(), accountID: "a1")
        try await bounded("syncDelta after 500") { try await engine.syncDelta() }

        #expect(store.accounts().first?.syncCursor == "GOOD-TOKEN")
        #expect(store.accounts().first?.state == .failed)
        // One request: the delta. No page walk was started.
        #expect(seen.all.count == 1)
    }

    @Test("currentCursor asks for $deltatoken=latest and returns the bare token")
    func currentCursorSeedsFromLatest() async throws {
        let seen = SeenRequests()
        StubURLProtocol.handler = { request in
            seen.record(request)
            return (200, [:], Data("""
            {"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=SEED-TOKEN",
             "value":[]}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let cursor = try await bounded("currentCursor") {
            try await self.makeProvider().currentCursor()
        }
        #expect(cursor == "SEED-TOKEN")
        let url = try #require(seen.all.first?.url.removingPercentEncoding)
        #expect(url.contains("$deltatoken=latest"))
    }

    @Test("a delta response with no deltaLink is a typed decoding failure, not a bogus cursor")
    func currentCursorWithoutDeltaLinkFails() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data(#"{"value":[]}"#.utf8)) }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        await #expect(throws: MailError.decodingFailed("graph delta token")) {
            try await self.bounded("currentCursor(no deltaLink)") {
                _ = try await provider.currentCursor()
            }
        }
    }
}
