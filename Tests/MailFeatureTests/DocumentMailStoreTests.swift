import Testing
import Foundation
@testable import MailFeature

@Suite("DocumentMailStore")
@MainActor struct DocumentMailStoreTests {
    private func makeStore() -> (DocumentMailStore, InMemoryDocumentStore) {
        let documents = InMemoryDocumentStore()
        return (DocumentMailStore(documents: documents), documents)
    }

    private func message(_ id: String, thread: String, date: Date,
                         read: Bool = false) -> MailMessage {
        MailMessage(id: id, threadID: thread, from: MailAddress(email: "b@x.com"),
                    subject: "Subject", date: date, isRead: read,
                    labelIDs: ["INBOX"], snippet: "snip")
    }

    @Test("a thread writes its own document plus the month index, not one blob")
    func shardsOnWrite() throws {
        let (store, documents) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000) // 2026-02
        let thread = MailThread(id: "t1", accountID: "a1",
                                messages: [message("m1", thread: "t1", date: when)])
        try store.upsertThread(thread)

        #expect(documents.storage["thread-t1"] != nil)
        #expect(documents.storage["index-a1-\(MonthShard.key(for: when))"] != nil)
        #expect(documents.storage.keys.contains("body-m1") == false)
    }

    @Test("summaries come back only for the months asked for")
    func summariesByMonth() throws {
        let (store, _) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        let march = Date(timeIntervalSince1970: 1_772_323_200)    // 2026-03-01
        try store.upsertThread(MailThread(id: "t1", accountID: "a1",
                                          messages: [message("m1", thread: "t1", date: january)]))
        try store.upsertThread(MailThread(id: "t2", accountID: "a1",
                                          messages: [message("m2", thread: "t2", date: march)]))

        let januaryOnly = store.summaries(accountID: "a1", months: [MonthShard.key(for: january)])
        #expect(januaryOnly.map(\.id) == ["t1"])
    }

    @Test("re-syncing the same thread replaces it instead of duplicating")
    func upsertDedupes() throws {
        let (store, _) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000)
        let first = MailThread(id: "t1", accountID: "a1",
                               messages: [message("m1", thread: "t1", date: when)])
        try store.upsertThread(first)
        var second = first
        second.messages.append(message("m2", thread: "t1", date: when.addingTimeInterval(60)))
        try store.upsertThread(second)

        let summaries = store.summaries(accountID: "a1", months: [MonthShard.key(for: when)])
        #expect(summaries.count == 1)
        #expect(summaries[0].messageCount == 2)
    }

    @Test("bodies live in their own documents")
    func bodiesSeparate() throws {
        let (store, documents) = makeStore()
        try store.saveBody(MessageBody(messageID: "m1", plainText: "hello", html: nil))
        #expect(documents.storage["body-m1"] != nil)
        #expect(store.body(messageID: "m1")?.plainText == "hello")
    }

    @Test("removing a thread clears its index row and document")
    func removeThread() throws {
        let (store, documents) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000)
        try store.upsertThread(MailThread(id: "t1", accountID: "a1",
                                          messages: [message("m1", thread: "t1", date: when)]))
        try store.removeThread("t1", accountID: "a1", date: when)

        #expect(documents.storage["thread-t1"] == nil)
        #expect(store.summaries(accountID: "a1", months: [MonthShard.key(for: when)]).isEmpty)
    }

    @Test("a thread that gains a message in a new month leaves no stale index row")
    func threadMovesMonth() throws {
        let (store, _) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        let february = Date(timeIntervalSince1970: 1_770_000_000) // 2026-02
        var thread = MailThread(id: "t1", accountID: "a1",
                                messages: [message("m1", thread: "t1", date: january)])
        try store.upsertThread(thread)
        thread.messages.append(message("m2", thread: "t1", date: february))
        try store.upsertThread(thread)

        let januaryRows = store.summaries(accountID: "a1", months: [MonthShard.key(for: january)])
        let februaryRows = store.summaries(accountID: "a1", months: [MonthShard.key(for: february)])
        #expect(januaryRows.isEmpty)
        #expect(februaryRows.map(\.id) == ["t1"])
    }

    @Test("accounts round-trip and never carry a token field")
    func accountsRoundTrip() throws {
        let (store, documents) = makeStore()
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me"))
        #expect(store.accounts().map(\.id) == ["a1"])
        let raw = try #require(documents.storage["accounts"])
        let text = String(decoding: raw, as: UTF8.self).lowercased()
        #expect(text.contains("token") == false)
    }
}
