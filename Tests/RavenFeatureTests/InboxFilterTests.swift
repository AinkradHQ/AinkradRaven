import Testing
import Foundation
@testable import RavenFeature

@Suite("Inbox filter")
@MainActor struct InboxFilterTests {
    private func thread(_ id: String, labels: [String], date: Date = Date()) -> MailThread {
        MailThread(id: id, accountID: "a1", messages: [
            MailMessage(id: "m-\(id)", threadID: id, from: MailAddress(email: "b@x.com"),
                        subject: "S", date: date, labelIDs: labels)
        ])
    }

    @Test("an archived thread (no INBOX label) is hidden from the Inbox list but remains stored and readable")
    func archivedThreadHiddenFromInboxButReadable() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        try store.upsertThread(thread("inboxed", labels: ["INBOX"]))
        try store.upsertThread(thread("archived", labels: []))

        let model = RavenViewModel(store: store)
        model.reload()

        #expect(model.visibleThreads.map(\.id) == ["inboxed"])
        // Still fully readable by id — archiving removes it from the inbox
        // VIEW, not from the store.
        #expect(store.thread("archived") != nil)
    }

    @Test("a trashed thread that still carries INBOX is excluded")
    func trashedThreadExcludedEvenWithInboxLabel() {
        let summary = ThreadSummary(id: "t1", accountID: "a1", subject: "S", participants: [],
                                    lastMessageDate: Date(), messageCount: 1, unreadCount: 0,
                                    isStarred: false, labelIDs: ["INBOX", "TRASH"], snippet: "")
        #expect(InboxFilter.isInInbox(summary) == false)
    }

    @Test("search_mail and unread_summary agree with the Inbox list about what's archived")
    func mcpToolsAgreeWithInboxList() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        try store.upsertThread(thread("inboxed", labels: ["INBOX", "UNREAD"]))
        try store.upsertThread(thread("archived", labels: ["UNREAD"]))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider(),
                            accountID: "a1")

        let searchResult = await RavenMCPOperations.run("search_mail", arguments: "{}",
                                                        store: store, outbox: outbox)
        #expect(searchResult.text.contains("inboxed"))
        #expect(searchResult.text.contains("archived") == false)

        let unreadResult = await RavenMCPOperations.run("unread_summary", arguments: "{}",
                                                        store: store, outbox: outbox)
        #expect(unreadResult.text.contains("inboxed"))
        #expect(unreadResult.text.contains("archived") == false)
    }
}
