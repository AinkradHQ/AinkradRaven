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
}
