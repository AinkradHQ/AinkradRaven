import Foundation
import Testing

@testable import RavenFeature

@Suite("DocumentMailStore")
@MainActor struct DocumentMailStoreTests: DocumentMailStoreFixtures {
    @Test("a thread writes its own document plus the month index, not one blob")
    func shardsOnWrite() throws {
        let (store, documents) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000)  // 2026-02
        let thread = MailThread(
            id: "t1", accountID: "a1",
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
        let march = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03-01
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: january)]))
        try store.upsertThread(
            MailThread(
                id: "t2", accountID: "a1",
                messages: [message("m2", thread: "t2", date: march)]))

        let januaryOnly = store.summaries(accountID: "a1", months: [MonthShard.key(for: january)])
        #expect(januaryOnly.map(\.id) == ["t1"])
    }

    @Test("re-syncing the same thread replaces it instead of duplicating")
    func upsertDedupes() throws {
        let (store, _) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000)
        let first = MailThread(
            id: "t1", accountID: "a1",
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
        try store.saveBody(
            MessageBody(messageID: "m1", plainText: "hello", html: nil),
            accountID: "a1")
        #expect(documents.storage["body-m1"] != nil)
        #expect(store.body(messageID: "m1")?.plainText == "hello")
    }

    @Test("removing a thread clears its index row and document")
    func removeThread() throws {
        let (store, documents) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000)
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: when)]))
        try store.removeThread("t1", accountID: "a1", date: when)

        #expect(documents.storage["thread-t1"] == nil)
        #expect(store.summaries(accountID: "a1", months: [MonthShard.key(for: when)]).isEmpty)
    }

    @Test("removing a thread uses the thread's own stored month, not a stale caller date")
    func removeThreadUsesStoredMonth() throws {
        let (store, _) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        let march = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03-01
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: january)]))
        // Caller passes a date in a different month than where the thread's summary
        // row actually lives (stale caller state, or the thread moved since it was read).
        try store.removeThread("t1", accountID: "a1", date: march)

        let januaryRows = store.summaries(accountID: "a1", months: [MonthShard.key(for: january)])
        #expect(januaryRows.isEmpty)
    }

    @Test("a thread that gains a message in a new month leaves no stale index row")
    func threadMovesMonth() throws {
        let (store, _) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        let february = Date(timeIntervalSince1970: 1_770_000_000)  // 2026-02
        var thread = MailThread(
            id: "t1", accountID: "a1",
            messages: [message("m1", thread: "t1", date: january)])
        try store.upsertThread(thread)
        thread.messages.append(message("m2", thread: "t1", date: february))
        try store.upsertThread(thread)

        let januaryRows = store.summaries(accountID: "a1", months: [MonthShard.key(for: january)])
        let februaryRows = store.summaries(accountID: "a1", months: [MonthShard.key(for: february)])
        #expect(januaryRows.isEmpty)
        #expect(februaryRows.map(\.id) == ["t1"])
    }

    // MARK: Thread merge (locally computed threading)

    @Test("merging a thread away leaves no document and no index row anywhere")
    func mergeRemovesLosingThread() throws {
        let (store, documents) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01
        let march = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: january)]))
        try store.upsertThread(
            MailThread(
                id: "t2", accountID: "a1",
                messages: [message("m2", thread: "t2", date: march)]))

        let winner = try #require(store.thread("t1"))
        try store.mergeThreads(losingIDs: ["t2"], into: winner)

        #expect(documents.storage["thread-t2"] == nil)
        // Every month shard the account has ever written, not just the current one.
        let months = try registeredMonths(documents, accountID: "a1")
        #expect(months.count == 2)
        for month in months {
            let rows = store.summaries(accountID: "a1", months: [month])
            #expect(
                rows.contains { $0.id == "t2" } == false,
                "t2 must not survive in the \(month) shard")
        }
        #expect(store.summaries(accountID: "a1", months: months).map(\.id) == ["t1"])
    }

    /// A thread can have occupied several month shards over its life. A merge
    /// must clean all of them, not only the one its last message currently
    /// lands in — otherwise the inbox shows a ghost row for a thread that no
    /// longer exists.
    @Test("a losing thread is cleaned out of every month it ever occupied")
    func mergeCleansEveryMonthEverOccupied() throws {
        let (store, documents) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01
        let february = Date(timeIntervalSince1970: 1_770_000_000)  // 2026-02
        let march = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03

        // t2 starts in January, then gains a February message: upsertThread's
        // drift repair moves the row. Plant a stale January row by hand so the
        // merge is proven to sweep a month it no longer claims to live in.
        var losing = MailThread(
            id: "t2", accountID: "a1",
            messages: [message("m2", thread: "t2", date: january)])
        try store.upsertThread(losing)
        losing.messages.append(message("m3", thread: "t2", date: february))
        try store.upsertThread(losing)
        let januaryKey = DocumentKeys.index(accountID: "a1", month: MonthShard.key(for: january))
        documents.setData(try coder.0.encode([losing.summary()]), forKey: januaryKey)

        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: march)]))
        let winner = try #require(store.thread("t1"))
        try store.mergeThreads(losingIDs: ["t2"], into: winner)

        for month in [january, february, march].map(MonthShard.key(for:)) {
            let rows = store.summaries(accountID: "a1", months: [month])
            #expect(
                rows.contains { $0.id == "t2" } == false,
                "t2 must be gone from the \(month) shard")
        }
    }

    @Test("the merged thread holds the deduped union of both message lists, oldest first")
    func mergeUnionsMessages() throws {
        let (store, _) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)
        let february = Date(timeIntervalSince1970: 1_770_000_000)
        let march = Date(timeIntervalSince1970: 1_772_323_200)
        try store.upsertThread(
            MailThread(
                id: "t2", accountID: "a1",
                messages: [
                    message("m2", thread: "t2", date: february),
                    message("shared", thread: "t2", date: january, read: true),
                ]))
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    message("shared", thread: "t1", date: january, read: true),
                    message("m1", thread: "t1", date: march),
                ]))

        let winner = try #require(store.thread("t1"))
        try store.mergeThreads(losingIDs: ["t2"], into: winner)

        let merged = try #require(store.thread("t1"))
        #expect(merged.messages.map(\.id) == ["shared", "m2", "m1"])
        #expect(merged.messages.map(\.date) == [january, february, march])

        let rows = store.summaries(accountID: "a1", months: [MonthShard.key(for: march)])
        let row = try #require(rows.first { $0.id == "t1" })
        #expect(row.messageCount == 3)
        #expect(row.unreadCount == 2)
        #expect(row.lastMessageDate == march)
    }

    /// `body-<messageID>` is keyed by MESSAGE, not by thread, so a change of
    /// thread identity must leave every body exactly where it was.
    @Test("a merge does not delete or rewrite any body")
    func mergeLeavesBodiesReachable() throws {
        let (store, documents) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)
        let march = Date(timeIntervalSince1970: 1_772_323_200)
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: january)]))
        try store.upsertThread(
            MailThread(
                id: "t2", accountID: "a1",
                messages: [message("m2", thread: "t2", date: march)]))
        try store.saveBody(
            MessageBody(messageID: "m1", plainText: "one", html: nil),
            accountID: "a1")
        try store.saveBody(
            MessageBody(messageID: "m2", plainText: "two", html: nil),
            accountID: "a1")
        let before = documents.storage["body-m2"]

        let winner = try #require(store.thread("t1"))
        try store.mergeThreads(losingIDs: ["t2"], into: winner)

        #expect(store.body(messageID: "m1")?.plainText == "one")
        #expect(store.body(messageID: "m2")?.plainText == "two")
        #expect(documents.storage["body-m2"] == before, "a merge must not rewrite a body")
    }

    @Test("an unknown losing id is a no-op for that id, not a throw")
    func mergeIgnoresUnknownLosingID() throws {
        let (store, _) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)
        let march = Date(timeIntervalSince1970: 1_772_323_200)
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: january)]))
        try store.upsertThread(
            MailThread(
                id: "t2", accountID: "a1",
                messages: [message("m2", thread: "t2", date: march)]))

        let winner = try #require(store.thread("t1"))
        // Partial knowledge must not fail the whole merge: t2 still merges.
        try store.mergeThreads(losingIDs: ["ghost", "t2"], into: winner)

        let merged = try #require(store.thread("t1"))
        #expect(merged.messages.map(\.id) == ["m1", "m2"])
    }

    @Test("a merge refuses to clobber a corrupt document")
    func mergeRefusesCorruptDocuments() throws {
        let january = Date(timeIntervalSince1970: 1_767_225_600)
        let march = Date(timeIntervalSince1970: 1_772_323_200)

        // A corrupt LOSING thread document: the merge must not delete it, and
        // must not write the winner either.
        do {
            let (store, documents) = makeStore()
            try store.upsertThread(
                MailThread(
                    id: "t1", accountID: "a1",
                    messages: [message("m1", thread: "t1", date: january)]))
            let winner = try #require(store.thread("t1"))
            let garbage = Data("not JSON".utf8)
            documents.setData(garbage, forKey: DocumentKeys.thread("t2"))

            #expect(throws: MailError.documentCorrupt(key: DocumentKeys.thread("t2"))) {
                try store.mergeThreads(losingIDs: ["t2"], into: winner)
            }
            #expect(
                documents.storage[DocumentKeys.thread("t2")] == garbage,
                "the damaged document must stay recoverable")
            #expect(store.lastCorruptDocumentKey == DocumentKeys.thread("t2"))
        }

        // A corrupt month INDEX shard: the read-modify-write must refuse too.
        do {
            let (store, documents) = makeStore()
            try store.upsertThread(
                MailThread(
                    id: "t1", accountID: "a1",
                    messages: [message("m1", thread: "t1", date: march)]))
            try store.upsertThread(
                MailThread(
                    id: "t2", accountID: "a1",
                    messages: [message("m2", thread: "t2", date: january)]))
            let winner = try #require(store.thread("t1"))
            let key = DocumentKeys.index(accountID: "a1", month: MonthShard.key(for: january))
            let garbage = Data("{{{".utf8)
            documents.setData(garbage, forKey: key)

            #expect(throws: MailError.documentCorrupt(key: key)) {
                try store.mergeThreads(losingIDs: ["t2"], into: winner)
            }
            #expect(documents.storage[key] == garbage)
            #expect(
                documents.storage[DocumentKeys.thread("t2")] != nil,
                "no write may land when any read-modify-write path had to refuse")
        }
    }

    @Test("accounts round-trip and never carry a token field")
    func accountsRoundTrip() throws {
        let (store, documents) = makeStore()
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me"))
        #expect(store.accounts().map(\.id) == ["a1"])
        let raw = try #require(documents.storage["accounts"])
        let text = String(decoding: raw, as: UTF8.self).lowercased()
        #expect(text.contains("token") == false)
    }
}
