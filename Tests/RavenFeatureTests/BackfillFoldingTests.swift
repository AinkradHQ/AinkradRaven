import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// The wiring, not the logic.
///
/// `ThreadFolding.fold` was written, tested and mutation-verified while
/// `SyncEngine.backfill` still called `store.upsertThread` directly — so every one
/// of those tests passed against code production never executed. That is the same
/// shape as Task 14's IDLE watcher: correct, covered, and reachable from nothing.
/// A unit test of `fold` cannot catch it by construction; only a test that drives
/// `backfill` and inspects the store can.
///
/// So these tests deliberately go through `SyncEngine` rather than calling `fold`,
/// and the assertions are about what a SECOND page does to a FIRST page's write —
/// which is exactly the sequence a real mailbox walk produces and no single-page
/// test can express.
@Suite("Backfill folds multi-mailbox pages")
@MainActor struct BackfillFoldingTests {

    private func message(_ messageID: String, labels: [String], id: String,
                         date: Date = Date(timeIntervalSince1970: 1_000)) -> MailMessage {
        MailMessage(id: id, threadID: "t1", rfc822MessageID: messageID,
                    from: MailAddress(email: "s@example.test"), subject: "Subject 1",
                    date: date, isRead: true, labelIDs: labels, snippet: "s")
    }

    private func engine(_ pages: [ThreadPage]) -> (SyncEngine, DocumentMailStore, FakeMailProvider) {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        provider.pages = pages
        let engine = SyncEngine(store: store, provider: provider, accountID: "a1")
        return (engine, store, provider)
    }

    // MARK: - The defect

    @Test("a second mailbox's page does not erase the first page's labels")
    func backfillFoldsRatherThanReplaces() async throws {
        // The same message, arriving twice: once as INBOX's copy, once as the
        // copy the server also lists under a label. Same `Message-ID`, same thread
        // id, different locators — precisely what `IMAPProvider.fetchThreads`
        // emits when it pages from one mailbox to the next.
        let inboxPage = ThreadPage(threads: [
            MailThread(id: "t1", accountID: "a1",
                       messages: [message("<m1@example.test>", labels: ["INBOX"], id: "imap.7.1.aW5ib3g")])
        ], nextPageToken: "p2")
        let labelPage = ThreadPage(threads: [
            MailThread(id: "t1", accountID: "a1",
                       messages: [message("<m1@example.test>", labels: ["Work"], id: "imap.7.9.V29yaw")])
        ], nextPageToken: nil)
        let (engine, store, _) = engine([inboxPage, labelPage])

        try await engine.backfill()

        let thread = try #require(store.thread("t1"))
        // Before the fix this was `["Work"]` — the inbox label gone, the thread
        // filtered out of the inbox list, and the mail invisible.
        #expect(thread.messages.count == 1)
        #expect(thread.messages[0].labelIDs == ["INBOX", "Work"])
    }

    @Test("one message listed in two mailboxes is stored once, not twice")
    func foldingDoesNotDuplicateTheMessage() async throws {
        let (engine, store, _) = engine([
            ThreadPage(threads: [MailThread(id: "t1", accountID: "a1", messages: [
                message("<m1@example.test>", labels: ["INBOX"], id: "imap.7.1.aW5ib3g")])],
                nextPageToken: "p2"),
            ThreadPage(threads: [MailThread(id: "t1", accountID: "a1", messages: [
                message("<m1@example.test>", labels: ["Work"], id: "imap.7.9.V29yaw")])],
                nextPageToken: nil),
        ])

        try await engine.backfill()

        // Matched on `Message-ID`, not on the mailbox-scoped locator — otherwise
        // the user sees one message rendered as two.
        #expect(try #require(store.thread("t1")).messages.count == 1)
    }

    @Test("a message only the first page carried is not dropped by the second")
    func foldingCarriesOverUnmentionedMessages() async throws {
        let (engine, store, _) = engine([
            ThreadPage(threads: [MailThread(id: "t1", accountID: "a1", messages: [
                message("<m1@example.test>", labels: ["INBOX"], id: "imap.7.1.a"),
                message("<m2@example.test>", labels: ["INBOX"], id: "imap.7.2.b",
                        date: Date(timeIntervalSince1970: 2_000))])],
                nextPageToken: "p2"),
            // The label mailbox holds only the second message. Replacing would
            // delete the first from the thread on every sync.
            ThreadPage(threads: [MailThread(id: "t1", accountID: "a1", messages: [
                message("<m2@example.test>", labels: ["Work"], id: "imap.7.9.c",
                        date: Date(timeIntervalSince1970: 2_000))])],
                nextPageToken: nil),
        ])

        try await engine.backfill()

        let thread = try #require(store.thread("t1"))
        #expect(thread.messages.count == 2)
        #expect(thread.messages.compactMap(\.rfc822MessageID)
                == ["<m1@example.test>", "<m2@example.test>"])
    }

    // MARK: - The counter

    @Test("the synced count counts threads, not writes")
    func syncedCountIsByIdentity() async throws {
        let (engine, _, _) = engine([
            ThreadPage(threads: [MailThread(id: "t1", accountID: "a1", messages: [
                message("<m1@example.test>", labels: ["INBOX"], id: "imap.7.1.a")])],
                nextPageToken: "p2"),
            ThreadPage(threads: [MailThread(id: "t1", accountID: "a1", messages: [
                message("<m1@example.test>", labels: ["Work"], id: "imap.7.9.b")])],
                nextPageToken: nil),
        ])

        // Observed as it is PUBLISHED, not read afterwards: `backfill` ends by
        // setting `.idle`, so the count the user actually sees exists only in the
        // progress states along the way. That is also the number being asserted —
        // the badge in Settings renders exactly this.
        var progress: [Int] = []
        engine.onChange = { [weak engine] in
            if case .backfilling(let synced) = engine?.state { progress.append(synced) }
        }

        try await engine.backfill()

        // One thread, reached twice. Counting writes reported double and made a
        // 212-message account read as 400+ synced.
        #expect(progress.last == 1)
        #expect(progress.allSatisfy { $0 <= 1 })
    }
}
