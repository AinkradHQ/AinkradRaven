import Testing
import Foundation
@testable import MailFeature

@Suite("Sync delta")
@MainActor struct SyncDeltaTests {
    private func setUp(_ provider: FakeMailProvider, cursor: String?)
        throws -> (SyncEngine, DocumentMailStore) {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", syncCursor: cursor, state: .ready))
        return (SyncEngine(store: store, provider: provider, accountID: "a1"), store)
    }

    private func thread(_ id: String, date: Date) -> MailThread {
        MailThread(id: id, accountID: "a1", messages: [
            MailMessage(id: "m-\(id)", threadID: id, from: MailAddress(email: "b@x.com"),
                        subject: "S", date: date, labelIDs: ["INBOX"], snippet: "s")
        ])
    }

    @Test("changed threads are refetched and stored")
    func appliesChanges() async throws {
        let now = Date()
        let provider = FakeMailProvider()
        provider.threadsByID = ["t1": thread("t1", date: now)]
        provider.deltas = [MailDelta(changedThreadIDs: ["t1"], removedThreadIDs: [], newCursor: "c2")]
        let (engine, store) = try setUp(provider, cursor: "c1")

        try await engine.syncDelta()
        #expect(store.thread("t1") != nil)
        #expect(store.accounts().first?.syncCursor == "c2")
    }

    @Test("removed threads disappear from the index")
    func appliesRemovals() async throws {
        let now = Date()
        let provider = FakeMailProvider()
        provider.deltas = [MailDelta(changedThreadIDs: [], removedThreadIDs: ["t1"], newCursor: "c2")]
        let (engine, store) = try setUp(provider, cursor: "c1")
        try store.upsertThread(thread("t1", date: now))

        try await engine.syncDelta()
        #expect(store.summaries(accountID: "a1", months: [MonthShard.key(for: now)]).isEmpty)
    }

    @Test("a thread deleted server-side mid-delta is skipped, not fatal")
    func toleratesVanishedThread() async throws {
        let provider = FakeMailProvider()
        provider.deltas = [MailDelta(changedThreadIDs: ["gone"], removedThreadIDs: [], newCursor: "c2")]
        // threadsByID has no "gone", so fetchThread throws .unknownThread
        let (engine, store) = try setUp(provider, cursor: "c1")

        try await engine.syncDelta()
        #expect(store.accounts().first?.syncCursor == "c2")
    }

    @Test("an expired cursor falls back to a full backfill")
    func expiredCursorRebackfills() async throws {
        let now = Date()
        let provider = FakeMailProvider()
        provider.failures["fetchDelta"] = [MailError.providerFailed(status: 404, message: "cursor too old")]
        provider.pages = [ThreadPage(threads: [thread("t9", date: now)], nextPageToken: nil)]
        provider.cursor = "c-fresh"
        let (engine, store) = try setUp(provider, cursor: "stale")

        try await engine.syncDelta()
        #expect(store.thread("t9") != nil)
        #expect(store.accounts().first?.syncCursor == "c-fresh")
    }

    @Test("no cursor means backfill, not a delta call")
    func noCursorBackfills() async throws {
        let provider = FakeMailProvider()
        provider.pages = [ThreadPage(threads: [], nextPageToken: nil)]
        provider.cursor = "c-first"
        let (engine, store) = try setUp(provider, cursor: nil)

        try await engine.syncDelta()
        #expect(store.accounts().first?.syncCursor == "c-first")
    }

    @Test("a transient fetchThread failure holds the cursor back and surfaces lastError")
    func transientThreadFailureHoldsCursor() async throws {
        let now = Date()
        let provider = FakeMailProvider()
        provider.threadsByID = ["t2": thread("t2", date: now)]
        provider.deltas = [MailDelta(changedThreadIDs: ["t1", "t2"], removedThreadIDs: [], newCursor: "c2")]
        // Only the FIRST fetchThread call (for "t1") fails transiently.
        provider.failures["fetchThread"] = [MailError.providerFailed(status: 500, message: "boom")]
        let (engine, store) = try setUp(provider, cursor: "c1")

        try await engine.syncDelta()
        #expect(store.accounts().first?.syncCursor == "c1", "cursor must not advance past an unapplied change")
        #expect(store.accounts().first?.lastError != nil)
        #expect(store.thread("t2") != nil, "sibling thread that fetched fine should still be stored")
    }

    @Test("an unknownThread failure still skips silently and still advances the cursor")
    func unknownThreadStillAdvancesCursor() async throws {
        let now = Date()
        let provider = FakeMailProvider()
        provider.threadsByID = ["t2": thread("t2", date: now)]
        provider.deltas = [MailDelta(changedThreadIDs: ["gone", "t2"], removedThreadIDs: [], newCursor: "c2")]
        // "gone" isn't in threadsByID, so fetchThread throws .unknownThread for it.
        let (engine, store) = try setUp(provider, cursor: "c1")

        try await engine.syncDelta()
        #expect(store.accounts().first?.syncCursor == "c2")
        #expect(store.thread("t2") != nil)
    }

    @Test("a subsequent successful syncDelta recovers and advances the cursor")
    func recoversAfterTransientFailure() async throws {
        let now = Date()
        let provider = FakeMailProvider()
        provider.threadsByID = ["t1": thread("t1", date: now)]
        provider.deltas = [
            MailDelta(changedThreadIDs: ["t1"], removedThreadIDs: [], newCursor: "c2"),
            MailDelta(changedThreadIDs: ["t1"], removedThreadIDs: [], newCursor: "c3")
        ]
        provider.failures["fetchThread"] = [MailError.providerFailed(status: 500, message: "boom")]
        let (engine, store) = try setUp(provider, cursor: "c1")

        try await engine.syncDelta()
        #expect(store.accounts().first?.syncCursor == "c1")

        try await engine.syncDelta()
        #expect(store.accounts().first?.syncCursor == "c3")
        #expect(store.thread("t1") != nil)
    }

    @Test("a rateLimited fetchDelta failure does not trigger a full backfill")
    func rateLimitedDoesNotBackfill() async throws {
        let provider = FakeMailProvider()
        provider.failures["fetchDelta"] = [MailError.rateLimited(retryAfter: 30)]
        provider.pages = [ThreadPage(threads: [], nextPageToken: nil)]
        provider.cursor = "c-backfill"
        let (engine, store) = try setUp(provider, cursor: "c1")

        try await engine.syncDelta()
        #expect(store.accounts().first?.syncCursor == "c1", "cursor should be untouched, not replaced by a backfill cursor")
        #expect(store.accounts().first?.lastError != nil)
    }
}
