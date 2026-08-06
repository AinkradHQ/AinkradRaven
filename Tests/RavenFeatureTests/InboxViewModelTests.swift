import Testing
import Foundation
@testable import RavenFeature

/// Fails every `enqueue` — used to exercise the path where the local store
/// mutation succeeds but queueing it for the provider does not, which a real
/// `Outbox` cannot be made to do through its public API (see `MutationOutbox`'s
/// documentation).
@MainActor private final class FailingOutbox: MutationOutbox {
    struct Failure: Error {}
    private(set) var attempts = 0
    /// Flip to `false` mid-test to prove a later SUCCESSFUL mutation clears a
    /// row error a previous failed one left behind.
    var shouldFail = true
    func enqueue(_ operation: OutboxEntry.Operation, accountID: String?) throws -> UUID {
        attempts += 1
        if shouldFail { throw Failure() }
        return UUID()
    }
}

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

    // MARK: Keyboard focus

    @Test("j/k move focus through the visible list and wrap at either end")
    func keyboardFocusMovesAndWraps() throws {
        let (model, store) = try makeModel()
        let now = Date()
        try store.upsertThread(thread("a", subject: "A", unread: false, date: now))
        try store.upsertThread(thread("b", subject: "B", unread: false, date: now.addingTimeInterval(-1)))
        try store.upsertThread(thread("c", subject: "C", unread: false, date: now.addingTimeInterval(-2)))
        model.reload()
        // newest-first order is a, b, c
        #expect(model.focusedThreadID == nil)

        model.moveFocus(by: 1)
        #expect(model.focusedThreadID == "a")
        model.moveFocus(by: 1)
        #expect(model.focusedThreadID == "b")
        model.moveFocus(by: 1)
        #expect(model.focusedThreadID == "c")
        // wraps forward past the last row back to the first
        model.moveFocus(by: 1)
        #expect(model.focusedThreadID == "a")
        // wraps backward past the first row to the last
        model.moveFocus(by: -1)
        #expect(model.focusedThreadID == "c")
    }

    @Test("moving focus with an empty visible list clears focus rather than crashing")
    func keyboardFocusEmptyList() throws {
        let (model, _) = try makeModel()
        model.reload()
        model.moveFocus(by: 1)
        #expect(model.focusedThreadID == nil)
    }

    // MARK: Bulk actions

    @Test("archiving a multi-selection enqueues ONE mutation carrying every id")
    func archiveSelectionEnqueuesOneMutation() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        let model = RavenViewModel(store: store, outbox: outbox)
        let now = Date()
        try store.upsertThread(thread("a", subject: "A", unread: false, date: now))
        try store.upsertThread(thread("b", subject: "B", unread: false, date: now.addingTimeInterval(-1)))
        try store.upsertThread(thread("c", subject: "C", unread: false, date: now.addingTimeInterval(-2)))
        model.reload()

        model.clickRow("a", shift: false, command: false)
        model.clickRow("c", shift: true, command: false)
        #expect(model.multiSelection == ["a", "b", "c"])

        model.archiveActive()

        #expect(outbox.pending().count == 1)
        guard case .labels(let mutation)? = outbox.pending().first?.operation else {
            Issue.record("expected a queued label mutation")
            return
        }
        #expect(Set(mutation.threadIDs) == ["a", "b", "c"])
        #expect(mutation.remove == ["INBOX"])

        // and every affected row in the store actually lost INBOX
        for id in ["a", "b", "c"] {
            #expect(store.thread(id)?.messages.allSatisfy { !$0.labelIDs.contains("INBOX") } == true)
        }
    }

    @Test("mark-unread round-trips: unread -> read -> unread")
    func markUnreadRoundTrips() throws {
        let (model, store) = try makeModel()
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: true, date: now))
        model.reload()

        model.setRead(["t1"], read: true)
        #expect(store.thread("t1")?.unreadCount == 0)

        model.setRead(["t1"], read: false)
        #expect(store.thread("t1")?.unreadCount == 1)
    }

    @Test("toggling unread on the active selection flips read threads to unread")
    func toggleUnreadActiveFlipsReadToUnread() throws {
        let (model, store) = try makeModel()
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: false, date: now))
        model.reload()
        model.moveFocus(by: 1)
        #expect(model.focusedThreadID == "t1")

        model.toggleUnreadActive()

        #expect(store.thread("t1")?.unreadCount == 1)
    }

    // MARK: Failure surfacing

    @Test("a failed enqueue leaves the local mutation applied but surfaces a per-row error, not silent success")
    func failedEnqueueSurfacesRowError() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        let outbox = FailingOutbox()
        let model = RavenViewModel(store: store, outbox: outbox)
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: false, date: now))
        model.reload()

        model.archive(["t1"])

        // the local store change still happened — local-first still applies
        #expect(store.thread("t1")?.messages.allSatisfy { !$0.labelIDs.contains("INBOX") } == true)
        // but the failure is observable, not swallowed
        #expect(model.rowErrors["t1"] != nil)
        #expect(outbox.attempts == 1)
    }

    @Test("a subsequent successful mutation clears a previously surfaced row error")
    func successClearsRowError() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                          displayName: "Me", state: .ready))
        let outbox = FailingOutbox()
        let model = RavenViewModel(store: store, outbox: outbox)
        let now = Date()
        try store.upsertThread(thread("t1", subject: "Hi", unread: false, date: now))
        model.reload()
        model.archive(["t1"])
        #expect(model.rowErrors["t1"] != nil)

        outbox.shouldFail = false
        model.star(["t1"], starred: true)
        #expect(model.rowErrors["t1"] == nil)
    }
}
