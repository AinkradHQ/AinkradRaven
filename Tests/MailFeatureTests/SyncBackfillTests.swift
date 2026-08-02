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

    @Test("a provider that echoes back the same page token terminates instead of hanging")
    func constantTokenTerminates() async throws {
        let provider = FakeMailProvider()
        // Every page hands back the exact token it was just given — a
        // pathological/hostile provider. Without cycle detection this would
        // spin `backfill()`'s repeat-loop forever on the main actor.
        provider.pages = [
            ThreadPage(threads: [], nextPageToken: "same"),
            ThreadPage(threads: [], nextPageToken: "same"),
            ThreadPage(threads: [], nextPageToken: "same"),
        ]
        let (engine, _) = makeEngine(provider)

        try await engine.backfill()

        #expect(engine.lastBackfillTruncated == true)
    }

    @Test("hitting the page cap truncates the backfill and records that it happened")
    func pageCapTruncates() async throws {
        // Five pages with distinct, ever-advancing tokens — no cycle here,
        // just more pages than the (test-injected, small) cap allows. Proves
        // the cap itself stops the walk, not the cycle detector.
        let provider = FakeMailProvider()
        provider.pages = (1...5).map { i in
            ThreadPage(threads: [], nextPageToken: i < 5 ? "p\(i + 1)" : nil)
        }
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let engine = SyncEngine(store: store, provider: provider, accountID: "a1",
                                 windowDays: 90, maxBackfillPages: 3)

        try await engine.backfill()

        #expect(engine.lastBackfillTruncated == true)
    }

    @Test("windowStart is pinned to UTC, matching MonthShard's convention")
    func windowStartUsesUTC() throws {
        let df = ISO8601DateFormatter()
        // Chosen so the 90-day lookback crosses the 2026 US DST start
        // (2026-03-08): a calendar pinned to a DST-observing zone like
        // America/Los_Angeles lands an hour off UTC across that boundary,
        // while a fixed-offset zone (e.g. Asia/Tokyo) would not discriminate
        // the bug at all, since plain day arithmetic is offset-independent
        // absent a DST transition in the window.
        let now = try #require(df.date(from: "2026-05-01T07:30:00Z"))

        let utcResult = SyncEngine.windowStart(from: now, windowDays: 90)

        var localBug = Calendar(identifier: .gregorian)
        localBug.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let buggyResult = localBug.date(byAdding: .day, value: -90, to: now)

        #expect(utcResult != buggyResult)
        #expect(utcResult == df.date(from: "2026-01-31T07:30:00Z"))
    }
}
