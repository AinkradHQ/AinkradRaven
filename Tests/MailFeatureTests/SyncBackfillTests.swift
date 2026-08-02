import Testing
import Foundation
@testable import MailFeature

@Suite("Sync backfill")
@MainActor struct SyncBackfillTests {
    private func makeEngine(_ provider: FakeMailProvider)
        -> (SyncEngine, DocumentMailStore) {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let engine = SyncEngine(store: store, provider: provider,
                                accountID: "a1", windowDays: 90)
        return (engine, store)
    }

    private func thread(_ id: String, date: Date) -> MailThread {
        MailThread(id: id, accountID: "a1", messages: [
            MailMessage(id: "m-\(id)", threadID: id, from: MailAddress(email: "b@x.com"),
                        subject: "S", date: date, labelIDs: ["INBOX"], snippet: "s")
        ])
    }

    @Test("backfill walks every page into the store")
    func walksPages() async throws {
        let now = Date()
        let provider = FakeMailProvider()
        provider.pages = [
            ThreadPage(threads: [thread("t1", date: now)], nextPageToken: "p2"),
            ThreadPage(threads: [thread("t2", date: now)], nextPageToken: nil),
        ]
        let (engine, store) = makeEngine(provider)
        try await engine.backfill()

        let ids = Set(store.summaries(accountID: "a1", months: [MonthShard.key(for: now)]).map(\.id))
        #expect(ids == ["t1", "t2"])
    }

    @Test("backfill seeds the account cursor so deltas can start")
    func seedsCursor() async throws {
        let provider = FakeMailProvider()
        provider.cursor = "c42"
        provider.pages = [ThreadPage(threads: [], nextPageToken: nil)]
        let (engine, store) = makeEngine(provider)
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me"))
        try await engine.backfill()

        #expect(store.accounts().first?.syncCursor == "c42")
        #expect(store.accounts().first?.state == .ready)
    }

    @Test("a failing page marks the account failed and preserves the error")
    func pageFailure() async throws {
        let provider = FakeMailProvider()
        provider.failures["fetchThreads"] = [MailError.providerFailed(status: 500, message: "boom")]
        let (engine, store) = makeEngine(provider)
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me"))

        await #expect(throws: MailError.self) { try await engine.backfill() }
        #expect(store.accounts().first?.state == .failed)
        #expect(store.accounts().first?.lastError?.isEmpty == false)
    }
}
