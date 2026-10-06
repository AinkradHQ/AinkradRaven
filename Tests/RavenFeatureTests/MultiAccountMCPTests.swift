import AinkradAppKit
import Foundation
import Testing

@testable import RavenFeature

/// The MCP half of the multi-account foundation: reads cover every account,
/// and drafts bind to exactly one. Split out of `MultiAccountTests`.
@Suite("Multi-account MCP")
@MainActor struct MultiAccountMCPTests: MultiAccountFixtures {
    // MARK: MCP account awareness

    @Test("MCP reads with no account_id cover every account")
    func mcpReadsCoverAllAccounts() async throws {
        let store = try store(accounts: ["a1", "a2"])
        let now = Date()
        try store.upsertThread(
            thread(
                "t-a1", account: "a1", subject: "invoice one",
                date: now, unread: true))
        try store.upsertThread(
            thread(
                "t-a2", account: "a2", subject: "invoice two",
                date: now.addingTimeInterval(-60), unread: true))
        try store.saveLabels([MailLabel(id: "L1", name: "one", kind: .user)], accountID: "a1")
        try store.saveLabels([MailLabel(id: "L2", name: "two", kind: .user)], accountID: "a2")
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let unread = await RavenMCPOperations.run(
            "unread_summary", arguments: "{}",
            store: store, outbox: outbox)
        #expect(unread.isError == false)
        #expect(unread.text.contains("t-a1"))
        #expect(unread.text.contains("t-a2"), "'what's unread' must mean every account")
        #expect(unread.text.contains("2 unread threads"))

        let search = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice"}"#,
            store: store, outbox: outbox)
        #expect(search.text.contains("t-a1"))
        #expect(search.text.contains("t-a2"))
        // Each row is attributed, so the agent can tell the mailboxes apart.
        #expect(search.text.contains("a1"))
        #expect(search.text.contains("a2"))

        let labels = await RavenMCPOperations.run(
            "list_labels", arguments: "{}",
            store: store, outbox: outbox)
        #expect(labels.text.contains("L1"))
        #expect(labels.text.contains("L2"))

        // And a scoped read still answers for exactly one account.
        let scoped = await RavenMCPOperations.run(
            "unread_summary",
            arguments: #"{"account_id":"a2"}"#,
            store: store, outbox: outbox)
        #expect(scoped.text.contains("t-a2"))
        #expect(scoped.text.contains("t-a1") == false)
    }

    @Test("read_thread names the account so a reply can go out from the right address")
    func readThreadNamesTheAccount() async throws {
        let store = try store(accounts: ["a1", "a2"])
        try store.upsertThread(thread("t-a2", account: "a2", subject: "two", date: Date()))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "read_thread",
            arguments: #"{"thread_id":"t-a2"}"#,
            store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("Account: a2"))
    }

    @Test("create_draft binds the draft to an account and refuses to guess between two")
    func createDraftResolvesAccount() async throws {
        let store = try store(accounts: ["a1", "a2"])
        try store.upsertThread(thread("t-a2", account: "a2", subject: "two", date: Date()))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        // Ambiguous: two accounts, no thread, no account_id.
        let refused = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"]}"#, store: store, outbox: outbox)
        #expect(refused.isError)
        #expect(refused.text.contains("account_id"))

        // Explicit.
        let explicit = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"],"account_id":"a1"}"#,
            store: store, outbox: outbox)
        #expect(explicit.isError == false)

        // Resolved from the thread being replied to.
        let inThread = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"],"thread_id":"t-a2"}"#,
            store: store, outbox: outbox)
        #expect(inThread.isError == false)
        let accounts = Set(DraftBox.shared.all().map { $0.message.accountID })
        #expect(accounts.contains("a1"))
        #expect(accounts.contains("a2"))
        for entry in DraftBox.shared.all() { DraftBox.shared.remove(entry.id) }
    }

    @Test("an unknown account_id on create_draft is refused rather than silently defaulted")
    func createDraftUnknownAccountRefused() async throws {
        let store = try store(accounts: ["a1"])
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        let result = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"],"account_id":"nope"}"#,
            store: store, outbox: outbox)
        #expect(result.isError)
    }
}
