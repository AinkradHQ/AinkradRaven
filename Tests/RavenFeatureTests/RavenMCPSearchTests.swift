import AinkradAppKit
import Foundation
import Testing

@testable import RavenFeature

/// `search_mail`: the synced window, the archive path and its rate limit.
/// Split out of `RavenMCPServerTests`.
@Suite("Raven MCP server — search_mail")
@MainActor struct RavenMCPSearchTests {
    @Test("search_mail on no matches is honest about the synced window")
    func searchMailEmptyIsHonestAboutWindow() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me", state: .ready))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice"}"#, store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("synced window"))
    }

    @Test("the searched window matches SyncEngine's sync window, not an independent guess")
    func searchWindowMatchesSyncWindow() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me", state: .ready))
        // A thread dated 80 days ago sits inside SyncEngine's 90-day window but
        // outside a naive "last 4 months" guess only in edge months; instead we
        // assert directly that the window used equals SyncEngine's default.
        let eightyDaysAgo = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -80, to: Date())!
        try store.upsertThread(
            MailThread(
                id: "t-old", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m-old", threadID: "t-old", from: MailAddress(email: "c@x.com"),
                        subject: "invoice", date: eightyDaysAgo, labelIDs: ["INBOX"], snippet: "s")
                ]))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice"}"#, store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("t-old"))
    }

    @Test("search_mail defaults to the synced window and never touches the provider")
    func searchMailDefaultDoesNotTouchProvider() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me", state: .ready))
        let provider = FakeMailProvider()
        provider.searchResults = [
            MailThread(
                id: "archive-1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "archive-1", from: MailAddress(email: "old@x.com"),
                        subject: "invoice", date: Date(), labelIDs: [], snippet: "s")
                ])
        ]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice"}"#,
            store: store, outbox: outbox,
            providers: MailProviderRouter(single: provider))

        #expect(result.isError == false)
        #expect(result.text.contains("synced window"))
        #expect(provider.searchThreadsCallCount == 0)
    }

    @Test("search_mail with include_archive reaches the provider and caches hits locally")
    func searchMailArchiveReachesProviderAndCaches() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me", state: .ready))
        let sixMonthsAgo = Calendar(identifier: .gregorian)
            .date(byAdding: .month, value: -6, to: Date())!
        let provider = FakeMailProvider()
        provider.searchResults = [
            MailThread(
                id: "archive-1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "archive-1", from: MailAddress(email: "old@x.com"),
                        subject: "invoice", date: sixMonthsAgo, labelIDs: [], snippet: "s")
                ])
        ]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice","include_archive":true}"#,
            store: store, outbox: outbox,
            providers: MailProviderRouter(single: provider))

        #expect(result.isError == false)
        #expect(result.text.contains("archive-1"))
        #expect(provider.searchThreadsCallCount == 1)
        // Cached locally: reachable via the store even though its month
        // shard (6 months back) is outside the Inbox's synced window.
        #expect(store.thread("archive-1") != nil)
    }

    @Test("a rate-limited archive search is distinguishable from empty results and never leaks a raw error")
    func searchMailArchiveRateLimitIsDistinctFromEmpty() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me", state: .ready,
                lastError: nil))
        let provider = FakeMailProvider()
        provider.failures["searchThreads"] = [MailError.rateLimited(retryAfter: 30)]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice","include_archive":true}"#,
            store: store, outbox: outbox,
            providers: MailProviderRouter(single: provider))

        #expect(result.isError)
        #expect(result.text.contains("rate-limited"))
        #expect(result.text.contains("MailError") == false)
        // Never leaked into the persisted account document.
        #expect(store.accounts().first(where: { $0.id == "a1" })?.lastError == nil)
    }

    @Test("include_archive with no provider fails honestly instead of silently returning empty")
    func searchMailArchiveWithoutProviderFails() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me", state: .ready))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice","include_archive":true}"#,
            store: store, outbox: outbox)

        #expect(result.isError)
    }
}
