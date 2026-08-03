import Foundation
import AinkradAppKit

/// Sharded JSON over the host's key→Data store. There is no database available
/// to a plugin, so the shape of the keys IS the index: one document per thread,
/// one per body, and one summary index per account-month.
@MainActor public final class DocumentMailStore: MailStore {
    private let documents: PluginDocumentStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(documents: PluginDocumentStore) {
        self.documents = documents
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Set whenever a document was present but could not be decoded. A
    /// corrupt document is NOT the same as a missing one, and the difference
    /// must be visible: silently reading it as empty is how one unreadable
    /// `accounts` document turns into a signed-out user.
    public private(set) var lastCorruptDocumentKey: String?

    /// Tolerant read, for pure reads only. A corrupt document reads as
    /// missing (there is nothing better to show), but records the fact in
    /// `lastCorruptDocumentKey` instead of swallowing it.
    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        do {
            return try loadStrict(type, key)
        } catch {
            return nil
        }
    }

    /// Strict read, for every read-modify-write path. Returns `nil` only when
    /// the document is genuinely ABSENT; a present-but-undecodable document
    /// throws `MailError.documentCorrupt`, which aborts the write.
    ///
    /// This is the whole fix for "a corrupt document silently becomes an empty
    /// one": `saveAccount`, `removeAccount` and `updateIndex` all read, mutate
    /// and write back, so treating a corrupt read as `[]` made the very next
    /// write destroy the original bytes permanently. Refusing to write leaves
    /// the damaged document intact and recoverable.
    private func loadStrict<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard let data = documents.data(forKey: key) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            lastCorruptDocumentKey = key
            throw MailError.documentCorrupt(key: key)
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) throws {
        documents.setData(try encoder.encode(value), forKey: key)
    }

    // MARK: Accounts

    public func accounts() -> [MailAccount] {
        load([MailAccount].self, DocumentKeys.accounts) ?? []
    }

    /// Read-modify-write, so it reads STRICTLY: if the accounts document is
    /// unreadable this throws rather than replacing every account with just
    /// this one.
    public func saveAccount(_ account: MailAccount) throws {
        var all = try loadStrict([MailAccount].self, DocumentKeys.accounts) ?? []
        if let index = all.firstIndex(where: { $0.id == account.id }) {
            all[index] = account
        } else {
            all.append(account)
        }
        try save(all, DocumentKeys.accounts)
    }

    public func removeAccount(_ id: String) throws {
        let all = try loadStrict([MailAccount].self, DocumentKeys.accounts) ?? []
        try save(all.filter { $0.id != id }, DocumentKeys.accounts)
    }

    // MARK: Threads

    public func summaries(accountID: String, months: [String]) -> [ThreadSummary] {
        months
            .flatMap { load([ThreadSummary].self, DocumentKeys.index(accountID: accountID, month: $0)) ?? [] }
            .sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    public func upsertThread(_ thread: MailThread) throws {
        try removeStaleIndexRow(threadID: thread.id, accountID: thread.accountID,
                                newMonth: MonthShard.key(for: thread.lastMessageDate))
        try save(thread, DocumentKeys.thread(thread.id))
        try updateIndex(accountID: thread.accountID, date: thread.lastMessageDate) { rows in
            let summary = thread.summary()
            if let index = rows.firstIndex(where: { $0.id == thread.id }) {
                rows[index] = summary
            } else {
                rows.append(summary)
            }
        }
    }

    /// A thread's month can change when a new message arrives. Without this the
    /// old shard keeps a stale summary and the inbox shows the thread twice.
    private func removeStaleIndexRow(threadID: String, accountID: String,
                                     newMonth: String) throws {
        guard let previous = try loadStrict(MailThread.self, DocumentKeys.thread(threadID))
        else { return }
        let previousMonth = MonthShard.key(for: previous.lastMessageDate)
        guard previousMonth != newMonth else { return }
        let key = DocumentKeys.index(accountID: accountID, month: previousMonth)
        var rows = try loadStrict([ThreadSummary].self, key) ?? []
        rows.removeAll { $0.id == threadID }
        try save(rows, key)
    }

    public func thread(_ id: String) -> MailThread? {
        load(MailThread.self, DocumentKeys.thread(id))
    }

    public func removeThread(_ id: String, accountID: String, date: Date) throws {
        // Prefer the thread's own stored lastMessageDate over the caller-supplied `date`:
        // the caller's date can be stale (read before the thread moved months), and trusting
        // it would leave the summary row behind in whatever shard it actually lives in — the
        // same ghost-row bug fixed for upsertThread via removeStaleIndexRow. Only fall back
        // to the caller's date when there's no stored thread left to read (already gone).
        let shardDate = try loadStrict(MailThread.self, DocumentKeys.thread(id))?
            .lastMessageDate ?? date
        documents.setData(nil, forKey: DocumentKeys.thread(id))
        try updateIndex(accountID: accountID, date: shardDate) { rows in
            rows.removeAll { $0.id == id }
        }
    }

    private func updateIndex(accountID: String, date: Date,
                             _ mutate: (inout [ThreadSummary]) -> Void) throws {
        let month = MonthShard.key(for: date)
        let key = DocumentKeys.index(accountID: accountID, month: month)
        var rows = try loadStrict([ThreadSummary].self, key) ?? []
        mutate(&rows)
        try save(rows, key)
        try registerMonth(month, accountID: accountID)
    }

    /// The host's document store is a bare key→Data map with no way to
    /// enumerate keys, so `purge` cannot discover which month shards an
    /// account has. This tiny registry — written only when a month shard is
    /// first touched — is what makes a complete sign-out purge possible at
    /// all. Without it, signing out would leave every thread and body
    /// readable on disk forever.
    private func registerMonth(_ month: String, accountID: String) throws {
        let key = DocumentKeys.indexMonths(accountID: accountID)
        var months = try loadStrict([String].self, key) ?? []
        guard !months.contains(month) else { return }
        months.append(month)
        try save(months, key)
    }

    /// Deletes every local document belonging to `accountID` — thread
    /// documents, message bodies, month index shards, the month registry, the
    /// label list, and the account row itself.
    ///
    /// Called on sign-out. Leaving this mail on disk after the user has
    /// disconnected the account is not a cache, it is a copy of their mailbox
    /// they have asked to be rid of. Best-effort per thread: one corrupt
    /// document must not abort the purge and strand the rest.
    public func purge(accountID: String) throws {
        let monthsKey = DocumentKeys.indexMonths(accountID: accountID)
        let months = load([String].self, monthsKey) ?? []
        for month in months {
            let indexKey = DocumentKeys.index(accountID: accountID, month: month)
            for row in load([ThreadSummary].self, indexKey) ?? [] {
                if let thread = load(MailThread.self, DocumentKeys.thread(row.id)) {
                    for message in thread.messages {
                        documents.setData(nil, forKey: DocumentKeys.body(message.id))
                    }
                }
                documents.setData(nil, forKey: DocumentKeys.thread(row.id))
            }
            documents.setData(nil, forKey: indexKey)
        }
        documents.setData(nil, forKey: monthsKey)
        documents.setData(nil, forKey: DocumentKeys.labels(accountID: accountID))
        try removeAccount(accountID)
    }

    // MARK: Bodies and labels

    public func body(messageID: String) -> MessageBody? {
        load(MessageBody.self, DocumentKeys.body(messageID))
    }

    public func saveBody(_ body: MessageBody) throws {
        try save(body, DocumentKeys.body(body.messageID))
    }

    public func labels(accountID: String) -> [MailLabel] {
        load([MailLabel].self, DocumentKeys.labels(accountID: accountID)) ?? []
    }

    public func saveLabels(_ labels: [MailLabel], accountID: String) throws {
        try save(labels, DocumentKeys.labels(accountID: accountID))
    }
}
