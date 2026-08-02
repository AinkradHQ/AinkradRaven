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

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = documents.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) throws {
        documents.setData(try encoder.encode(value), forKey: key)
    }

    // MARK: Accounts

    public func accounts() -> [MailAccount] {
        load([MailAccount].self, DocumentKeys.accounts) ?? []
    }

    public func saveAccount(_ account: MailAccount) throws {
        var all = accounts()
        if let index = all.firstIndex(where: { $0.id == account.id }) {
            all[index] = account
        } else {
            all.append(account)
        }
        try save(all, DocumentKeys.accounts)
    }

    public func removeAccount(_ id: String) throws {
        try save(accounts().filter { $0.id != id }, DocumentKeys.accounts)
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
        guard let previous = load(MailThread.self, DocumentKeys.thread(threadID)) else { return }
        let previousMonth = MonthShard.key(for: previous.lastMessageDate)
        guard previousMonth != newMonth else { return }
        let key = DocumentKeys.index(accountID: accountID, month: previousMonth)
        var rows = load([ThreadSummary].self, key) ?? []
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
        let shardDate = load(MailThread.self, DocumentKeys.thread(id))?.lastMessageDate ?? date
        documents.setData(nil, forKey: DocumentKeys.thread(id))
        try updateIndex(accountID: accountID, date: shardDate) { rows in
            rows.removeAll { $0.id == id }
        }
    }

    private func updateIndex(accountID: String, date: Date,
                             _ mutate: (inout [ThreadSummary]) -> Void) throws {
        let key = DocumentKeys.index(accountID: accountID, month: MonthShard.key(for: date))
        var rows = load([ThreadSummary].self, key) ?? []
        mutate(&rows)
        try save(rows, key)
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
