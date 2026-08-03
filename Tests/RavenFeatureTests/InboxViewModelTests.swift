import Testing
import Foundation
@testable import RavenFeature

@Suite("Inbox view model")
@MainActor struct InboxViewModelTests {
    private func makeModel() throws -> (RavenViewModel, DocumentMailStore) {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        return (RavenViewModel(store: store), store)
    }

    private func thread(_ id: String, subject: String, unread: Bool, date: Date) -> MailThread {
        MailThread(id: id, accountID: "a1", messages: [
            MailMessage(id: "m-\(id)", threadID: id, from: MailAddress(email: "b@x.com"),
                        subject: subject, date: date, isRead: !unread,
                        labelIDs: unread ? ["INBOX", "UNREAD"] : ["INBOX"], snippet: "s")
        ])
    }

    @Test("reload lists threads newest first")
    func ordersByDate() throws {
        let (model, store) = try makeModel()
        let now = Date()
        try store.upsertThread(thread("old", subject: "Old", unread: false,
                                      date: now.addingTimeInterval(-3600)))
        try store.upsertThread(thread("new", subject: "New", unread: false, date: now))
        model.reload()
        #expect(model.visibleThreads.map(\.id) == ["new", "old"])
    }

    @Test("the search field filters the visible list")
    func filters() throws {
        let (model, store) = try makeModel()
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Invoice", unread: false, date: now))
        try store.upsertThread(thread("t2", subject: "Lunch", unread: false, date: now))
        model.reload()
        model.searchText = "invoice"
        #expect(model.visibleThreads.map(\.id) == ["t1"])
    }

    @Test("selecting a thread marks it read locally and immediately")
    func selectionMarksRead() throws {
        let (model, store) = try makeModel()
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: true, date: now))
        model.reload()
        model.select("t1")
        #expect(model.selectedThread?.id == "t1")
        #expect(store.thread("t1")?.unreadCount == 0)
    }

    @Test("selecting an unread thread also queues the read on the outbox, not just the local store")
    func selectionEnqueuesOutboxMutation() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        let model = RavenViewModel(store: store, outbox: outbox)
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: true, date: now))
        model.reload()

        model.select("t1")

        #expect(outbox.pending().count == 1)
        guard case .labels(let mutation)? = outbox.pending().first?.operation else {
            Issue.record("expected a queued label mutation")
            return
        }
        #expect(mutation.threadIDs == ["t1"])
        #expect(mutation.remove == ["UNREAD"])
    }

    @Test("re-selecting an already-read thread does not queue a redundant mutation")
    func reselectingReadThreadDoesNotEnqueue() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        let model = RavenViewModel(store: store, outbox: outbox)
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: false, date: now))
        model.reload()

        model.select("t1")

        #expect(outbox.pending().isEmpty)
    }

    @Test("selecting an unknown id clears rather than crashes")
    func selectionMissing() throws {
        let (model, _) = try makeModel()
        model.select("nope")
        #expect(model.selectedThread == nil)
    }

    @Test("reload with no account clears the list rather than crashing")
    func noAccount() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let model = RavenViewModel(store: store)
        model.reload()
        #expect(model.visibleThreads.isEmpty)
    }

    @Test("reload drops a selection that left the synced window")
    func selectionClearedWhenThreadGone() throws {
        let (model, store) = try makeModel()
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: false, date: now))
        model.reload()
        model.select("t1")
        #expect(model.selectedThread?.id == "t1")
        try store.removeThread("t1", accountID: "a1", date: now)
        model.reload()
        #expect(model.selectedThread == nil)
    }
}
