import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// `bundle_by_sender`, in its own file: `RavenMCPServerTests` is already 400+
/// lines and this tool needs a shared fixture store of its own.
@Suite("Raven MCP bundle_by_sender")
@MainActor struct RavenMCPBundleBySenderTests {

    /// Two accounts, one correspondent written three ways (display name, mixed
    /// case, and the whole `Name <addr>` form in the address field), a second
    /// correspondent spanning both accounts, and one thread with no sender at
    /// all. A rule that grouped on the raw address string, or grouped per
    /// account, or dropped the senderless thread, would all still return a
    /// well-formed bundle list — which is what makes this fixture able to tell
    /// the right rule from a plausible wrong one.
    private func bundleFixtureStore() throws -> DocumentMailStore {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        for id in ["a1", "a2"] {
            try store.saveAccount(MailAccount(id: id, provider: .gmail,
                                              address: "\(id)@example.test",
                                              displayName: id, state: .ready))
        }
        let now = Date()
        func thread(_ id: String, _ account: String, _ from: MailAddress?,
                    _ minutesAgo: Double, unread: Bool = false) throws {
            try store.upsertThread(MailThread(id: id, accountID: account, messages: [
                MailMessage(id: "m-\(id)", threadID: id, from: from,
                            subject: "Subject \(id)", date: now.addingTimeInterval(-60 * minutesAgo),
                            isRead: !unread, labelIDs: ["INBOX"], snippet: "s")
            ]))
        }
        try thread("t-b1", "a1", MailAddress(email: "b@example.test", name: "Bea"), 30)
        try thread("t-b2", "a1", MailAddress(email: "B@Example.Test", name: "Beatrice"), 10,
                   unread: true)
        try thread("t-b3", "a2", MailAddress(email: "Bea <b@example.test>"), 50)
        try thread("t-c1", "a1", MailAddress(email: "c@example.test"), 40)
        try thread("t-c2", "a2", MailAddress(email: "c@example.test"), 20)
        try thread("t-none", "a1", nil, 15, unread: true)
        // Archived: in the month shard, but not in the inbox. Present so the
        // claim that this tool reads the SAME filtered set as `unread_summary`
        // and `search_mail` is observable — without it, a read of the raw
        // shards would produce identical output.
        try store.upsertThread(MailThread(id: "t-archived", accountID: "a1", messages: [
            MailMessage(id: "m-t-archived", threadID: "t-archived",
                        from: MailAddress(email: "d@example.test"),
                        subject: "Subject t-archived", date: now.addingTimeInterval(-60),
                        isRead: true, labelIDs: [], snippet: "s")
        ]))
        return store
    }

    @Test("bundle_by_sender reads the store only — it works with an empty provider router")
    func bundleBySenderNeedsNoProvider() async throws {
        let store = try bundleFixtureStore()
        #expect(store.accounts().count == 2)
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        // Genuinely empty: no provider is attached for either account, so any
        // attempt to reach one would have to fail or return nothing.
        let router = MailProviderRouter()
        #expect(router.isEmpty)
        #expect(router.provider(for: "a1") == nil)

        let result = await RavenMCPOperations.run("bundle_by_sender", arguments: "{}",
                                                 store: store, outbox: outbox,
                                                 providers: router)

        #expect(result.isError == false)
        #expect(result.text.contains("3 sender(s) over 6 thread(s)"))
        #expect(result.text.contains("b@example.test · 3 thread(s)"))
    }

    @Test("bundle_by_sender never calls a provider even when one is attached")
    func bundleBySenderDoesNotTouchProvider() async throws {
        let store = try bundleFixtureStore()
        #expect(store.accounts().count == 2)
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run("bundle_by_sender", arguments: "{}",
                                                 store: store, outbox: outbox,
                                                 providers: MailProviderRouter(single: provider))

        #expect(result.isError == false)
        #expect(provider.searchThreadsCallCount == 0)
        #expect(provider.appliedMutations.isEmpty)
        #expect(provider.sentMessages.isEmpty)
    }

    @Test("bundle_by_sender folds case and display names, and keeps a senderless thread in an explicit bucket")
    func bundleBySenderNormalises() async throws {
        let store = try bundleFixtureStore()
        #expect(store.accounts().count == 2)
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run("bundle_by_sender", arguments: "{}",
                                                 store: store, outbox: outbox)

        #expect(result.isError == false)
        // One bundle for b@example.test, not three; its threads span both accounts.
        #expect(result.text.contains("b@example.test · 3 thread(s), 1 unread"))
        #expect(result.text.contains("accounts a1=2, a2=1"))
        #expect(result.text.contains("threads t-b2, t-b1, t-b3"))
        // The senderless thread is counted, under a label no address can be.
        #expect(result.text.contains("(unknown sender) · 1 thread(s), 1 unread"))
        #expect(result.text.contains("t-none"))
        // The un-normalised spellings never appear as their own sender lines.
        #expect(result.text.contains("B@Example.Test") == false)
        #expect(result.text.contains("Bea <") == false)
        // The archived thread is in the shard but not in the inbox, so it is
        // neither bundled nor counted — the same filtered set the Inbox list,
        // `search_mail` and `unread_summary` see.
        #expect(store.summaries(accountID: "a1",
                                months: UnifiedInbox.recentMonths()).count == 5)
        #expect(result.text.contains("d@example.test") == false)
        #expect(result.text.contains("t-archived") == false)
    }

    @Test("an oversized limit is clamped to the cap rather than honoured")
    func limitIsClamped() {
        #expect(RavenMCPOperations.maxLimit == 200)
        #expect(RavenMCPOperations.boundedLimit(["limit": 100_000]) == 200)
        #expect(RavenMCPOperations.boundedLimit(["limit": 7]) == 7)
        #expect(RavenMCPOperations.boundedLimit([:]) == 25)
        #expect(RavenMCPOperations.boundedLimit(["limit": 0]) == nil)
        #expect(RavenMCPOperations.boundedLimit(["limit": -1]) == nil)
        #expect(RavenMCPOperations.boundedLimit(["limit": "7"]) == nil)
    }

    @Test("bundle_by_sender with account_id covers that account only, and without it spans all")
    func bundleBySenderScoping() async throws {
        let store = try bundleFixtureStore()
        #expect(store.accounts().count == 2)
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let scoped = await RavenMCPOperations.run(
            "bundle_by_sender", arguments: #"{"account_id":"a2"}"#, store: store, outbox: outbox)
        #expect(scoped.isError == false)
        #expect(scoped.text.contains("2 sender(s) over 2 thread(s)"))
        #expect(scoped.text.contains("accounts a2=1"))
        #expect(scoped.text.contains("a1=") == false, "a1's threads are out of scope")
        #expect(scoped.text.contains("t-b1") == false)

        let all = await RavenMCPOperations.run("bundle_by_sender", arguments: "{}",
                                               store: store, outbox: outbox)
        #expect(all.isError == false)
        #expect(all.text.contains("3 sender(s) over 6 thread(s)"))
        #expect(all.text.contains("a1="))
    }

    @Test("bundle_by_sender validates limit at the boundary and clamps an oversized one")
    func bundleBySenderLimitValidation() async throws {
        let store = try bundleFixtureStore()
        #expect(store.accounts().count == 2)
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        for bad in ["0", "-3", "\"5\""] {
            let result = await RavenMCPOperations.run(
                "bundle_by_sender", arguments: #"{"limit":\#(bad)}"#,
                store: store, outbox: outbox)
            #expect(result.isError, "limit \(bad) must be refused, not coerced")
            #expect(result.text.contains("positive integer"))
        }

        let limited = await RavenMCPOperations.run(
            "bundle_by_sender", arguments: #"{"limit":1}"#, store: store, outbox: outbox)
        #expect(limited.isError == false)
        #expect(limited.text.contains("1 sender(s) over 6 thread(s)"),
                "the thread total still counts every thread, only the senders are capped")
        #expect(limited.text.contains("c@example.test") == false)

        // Past the cap is clamped rather than refused: there are only 3 senders,
        // so the visible effect is that it succeeds and returns all of them.
        let huge = await RavenMCPOperations.run(
            "bundle_by_sender", arguments: #"{"limit":100000}"#, store: store, outbox: outbox)
        #expect(huge.isError == false)
        #expect(huge.text.contains("3 sender(s) over 6 thread(s)"))
        #expect(RavenMCPOperations.maxLimit == 200)
    }

    @Test("bundle_by_sender on an empty store says so rather than rendering an empty list")
    func bundleBySenderEmptyStore() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@example.test", displayName: "Me",
                                          state: .ready))
        #expect(store.summaries(accountID: "a1", months: UnifiedInbox.recentMonths()).isEmpty)
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run("bundle_by_sender", arguments: "{}",
                                                 store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("No threads in the synced window"))
    }

    @Test("bundle_by_sender is registered read-only and non-destructive with a parseable schema")
    func bundleBySenderRegistration() throws {
        let tool = try #require(RavenMCPServer.tools.first { $0.name == "bundle_by_sender" })
        #expect(tool.readOnly)
        #expect(tool.destructive == false)
        #expect(tool.operation == "bundle_by_sender")
        let parsed = try JSONSerialization.jsonObject(with: Data(tool.schemaJSON.utf8))
        let properties = try #require((parsed as? [String: Any])?["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["account_id", "limit"])
        // Registration through the real host spec, so a schema the host rejects
        // is a failure here rather than a tool that silently never appears.
        let made = RavenMCPServer.make(appID: "raven") { _, _ in
            AgentActionResult(text: "", isError: false)
        }
        #expect(made.failures.isEmpty)
    }
}
