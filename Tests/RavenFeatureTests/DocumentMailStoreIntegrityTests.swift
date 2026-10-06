import Foundation
import Testing

@testable import RavenFeature

/// Corrupt documents are surfaced rather than clobbered, and purge removes an
/// account completely. Split out of `DocumentMailStoreTests`.
@Suite("DocumentMailStore — corruption and purge")
@MainActor struct DocumentMailStoreIntegrityTests: DocumentMailStoreFixtures {
    // MARK: Corruption (ledger D3)

    @Test("a corrupt accounts document is not overwritten by the next write")
    func corruptAccountsDocumentIsNotClobbered() throws {
        let (store, documents) = makeStore()
        let garbage = Data("this is not JSON".utf8)
        documents.setData(garbage, forKey: DocumentKeys.accounts)

        // Read-modify-write cannot read what is there, so it must refuse to
        // write. Before the fix it read the corrupt document as `[]` and
        // saved a one-element array over it, destroying the real accounts
        // permanently on the very next save.
        #expect(throws: MailError.documentCorrupt(key: DocumentKeys.accounts)) {
            try store.saveAccount(
                MailAccount(
                    id: "a1", provider: .gmail,
                    address: "me@x.com", displayName: "Me"))
        }
        #expect(
            documents.storage[DocumentKeys.accounts] == garbage,
            "the original bytes must survive so the document can be recovered")

        // removeAccount is the same read-modify-write shape and must refuse too.
        #expect(throws: MailError.documentCorrupt(key: DocumentKeys.accounts)) {
            try store.removeAccount("a1")
        }
        #expect(documents.storage[DocumentKeys.accounts] == garbage)
    }

    @Test("a corrupt document is surfaced rather than being indistinguishable from absent")
    func corruptDocumentIsSurfaced() throws {
        let (store, documents) = makeStore()
        documents.setData(Data("not JSON".utf8), forKey: DocumentKeys.accounts)

        #expect(store.accounts().isEmpty)
        #expect(
            store.lastCorruptDocumentKey == DocumentKeys.accounts,
            "an unreadable document must not read as simply missing")
    }

    @Test("a corrupt month index is not overwritten by a thread upsert")
    func corruptIndexIsNotClobbered() throws {
        let (store, documents) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000)
        let key = DocumentKeys.index(accountID: "a1", month: MonthShard.key(for: when))
        let garbage = Data("{{{".utf8)
        documents.setData(garbage, forKey: key)

        #expect(throws: MailError.documentCorrupt(key: key)) {
            try store.upsertThread(
                MailThread(
                    id: "t1", accountID: "a1",
                    messages: [message("m1", thread: "t1", date: when)]))
        }
        #expect(documents.storage[key] == garbage)
    }

    // MARK: Purge

    @Test("purge removes every document belonging to the account, across months")
    func purgeRemovesEverything() throws {
        let (store, documents) = makeStore()
        let january = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01
        let march = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me"))
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: january)]))
        try store.upsertThread(
            MailThread(
                id: "t2", accountID: "a1",
                messages: [message("m2", thread: "t2", date: march)]))
        try store.saveBody(
            MessageBody(messageID: "m1", plainText: "secret", html: nil),
            accountID: "a1")
        try store.saveBody(
            MessageBody(messageID: "m2", plainText: "secret", html: nil),
            accountID: "a1")
        try store.saveLabels(
            [MailLabel(id: "INBOX", name: "Inbox", kind: .system)],
            accountID: "a1")

        try store.purge(accountID: "a1")

        #expect(store.accounts().isEmpty)
        #expect(documents.storage["thread-t1"] == nil)
        #expect(documents.storage["thread-t2"] == nil)
        #expect(documents.storage["body-m1"] == nil, "mail bodies must not survive a sign-out")
        #expect(documents.storage["body-m2"] == nil)
        #expect(
            documents.storage[
                DocumentKeys.index(
                    accountID: "a1",
                    month: MonthShard.key(for: january))] == nil)
        #expect(
            documents.storage[
                DocumentKeys.index(
                    accountID: "a1",
                    month: MonthShard.key(for: march))] == nil)
        #expect(documents.storage[DocumentKeys.labels(accountID: "a1")] == nil)
        #expect(documents.storage[DocumentKeys.indexMonths(accountID: "a1")] == nil)
    }

    /// The walk from index rows into thread documents cannot reach a body
    /// whose thread write never landed. Mail must not remain readable after
    /// sign-out, so the body registry has to catch it.
    @Test("purge removes a body whose thread document does not exist")
    func purgeRemovesOrphanedBody() throws {
        let (store, documents) = makeStore()
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "me@x.com", displayName: "Me"))
        // A body landed, but the thread write failed — no index row, no thread
        // document, nothing pointing at this body.
        try store.saveBody(
            MessageBody(messageID: "orphan", plainText: "private", html: nil),
            accountID: "a1")
        #expect(documents.storage["body-orphan"] != nil)

        try store.purge(accountID: "a1")

        #expect(
            documents.storage["body-orphan"] == nil,
            "an unreachable body must not survive sign-out")
        #expect(documents.storage[DocumentKeys.bodyIndex(accountID: "a1")] == nil)
    }

    @Test("purge leaves another account's documents alone")
    func purgeIsScopedToOneAccount() throws {
        let (store, documents) = makeStore()
        let when = Date(timeIntervalSince1970: 1_772_000_000)
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail,
                address: "one@x.com", displayName: "One"))
        try store.saveAccount(
            MailAccount(
                id: "a2", provider: .gmail,
                address: "two@x.com", displayName: "Two"))
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [message("m1", thread: "t1", date: when)]))
        try store.upsertThread(
            MailThread(
                id: "t2", accountID: "a2",
                messages: [message("m2", thread: "t2", date: when)]))

        try store.purge(accountID: "a1")

        #expect(store.accounts().map(\.id) == ["a2"])
        #expect(documents.storage["thread-t1"] == nil)
        #expect(documents.storage["thread-t2"] != nil)
    }
}
