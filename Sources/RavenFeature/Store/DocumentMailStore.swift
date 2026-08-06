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

    /// See `MailStore.mergeThreads`. Deliberately separate from `upsertThread`:
    /// that path repairs one thread's month drift, this one retires whole thread
    /// identities, and conflating them would put a destructive delete on the
    /// ordinary sync path.
    ///
    /// Every strict read happens BEFORE the first write. A merge touches several
    /// documents, so a corrupt one discovered halfway through would otherwise
    /// leave the mailbox in a state neither before nor after the merge — and the
    /// M0 rule is that a document which failed to decode is never clobbered.
    public func mergeThreads(losingIDs: [String], into thread: MailThread) throws {
        let retired = Set(losingIDs).subtracting([thread.id])
        var losing: [MailThread] = []
        for id in retired.sorted() {
            // Strict: a losing thread we cannot decode must not be deleted, and
            // its messages must not silently vanish from the merged thread.
            guard let document = try loadStrict(MailThread.self, DocumentKeys.thread(id))
            else { continue }   // unknown id — a no-op for this id, not a failure
            losing.append(document)
        }
        let merged = MailThread(id: thread.id, accountID: thread.accountID,
                                messages: Self.union(thread.messages, losing.flatMap(\.messages)))
        let survivingMonth = MonthShard.key(for: merged.lastMessageDate)

        // A thread can have occupied several month shards over its life, so the
        // sweep covers every month the account ever registered — not just the
        // one the losing thread's last message currently lands in.
        var months = try loadStrict([String].self,
                                    DocumentKeys.indexMonths(accountID: thread.accountID)) ?? []
        if !months.contains(survivingMonth) { months.append(survivingMonth) }
        var pending: [String: [ThreadSummary]] = [:]
        for month in months {
            let key = DocumentKeys.index(accountID: thread.accountID, month: month)
            let rows = try loadStrict([ThreadSummary].self, key) ?? []
            var updated = rows.filter { !retired.contains($0.id) && $0.id != thread.id }
            if month == survivingMonth { updated.append(merged.summary()) }
            if updated != rows { pending[key] = updated }
        }

        for (key, rows) in pending { try save(rows, key) }
        try registerMonth(survivingMonth, accountID: thread.accountID)
        for document in losing {
            documents.setData(nil, forKey: DocumentKeys.thread(document.id))
        }
        try save(merged, DocumentKeys.thread(merged.id))
    }

    /// Union of two message lists, deduped by message id — the winning thread's
    /// copy of a message wins — and ordered oldest-first, which is the order
    /// `MailThread.messages` documents and `lastMessageDate` depends on. The
    /// index tiebreak keeps the sort stable for messages sharing a timestamp.
    private static func union(_ winning: [MailMessage],
                             _ losing: [MailMessage]) -> [MailMessage] {
        var seen = Set<String>()
        let deduped = (winning + losing).filter { seen.insert($0.id).inserted }
        return deduped.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
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
        // Then every body the account ever wrote, including any whose thread
        // document never landed and which the walk above therefore could not
        // reach. See `saveBody` for why the walk alone is not enough.
        let bodyIndexKey = DocumentKeys.bodyIndex(accountID: accountID)
        for messageID in load([String].self, bodyIndexKey) ?? [] {
            documents.setData(nil, forKey: DocumentKeys.body(messageID))
        }
        documents.setData(nil, forKey: bodyIndexKey)
        documents.setData(nil, forKey: monthsKey)
        documents.setData(nil, forKey: DocumentKeys.labels(accountID: accountID))
        // The per-account provider-configuration documents. These are not mail, but
        // they are still "everything belonging to this account", and leaving them
        // means the next account that happens to be given the same id inherits a
        // stranger's server settings or folder list.
        //
        // `appleMailDirectory` was previously removed ONLY by
        // `ProviderFactory.signOut`, so any purge that did not go through
        // `RavenRuntime.signOut` — an MCP-driven one, a store-level one — left the
        // security-scoped bookmark behind. Removing it here as well makes the purge
        // complete on its own terms; the factory's own removal stays, because the
        // factory also has to relinquish the live access grant that bookmark backs.
        documents.setData(nil, forKey: DocumentKeys.appleMailDirectory(accountID: accountID))
        documents.setData(nil, forKey: DocumentKeys.imapSettings(accountID: accountID))
        documents.setData(nil, forKey: DocumentKeys.imapMailboxes(accountID: accountID))
        // The `label_with_reason` audit log. A new per-account document family,
        // wired into the purge in the same commit that introduced it —
        // `applemail-directory-<id>`, `imap-settings-<id>` and the IMAP app
        // password each shipped unpurged and had to be chased down later, and a
        // reason log is a record of what the user's mail said and why it was
        // filed, which is not something to leave behind after a sign-out.
        //
        // Every shard is found through the log's own month registry, then the
        // registry itself goes — the identical shape as `indexMonths`, because
        // the host store still cannot enumerate keys.
        let reasonMonthsKey = DocumentKeys.labelReasonMonths(accountID: accountID)
        for month in load([String].self, reasonMonthsKey) ?? [] {
            documents.setData(nil, forKey: DocumentKeys.labelReasons(accountID: accountID,
                                                                     month: month))
        }
        documents.setData(nil, forKey: reasonMonthsKey)
        try removeAccount(accountID)
    }

    // MARK: Label reasons

    /// How many stored reason records this build could not decode, summed over
    /// every `labelReasons` read since launch.
    ///
    /// Observable rather than swallowed, exactly as
    /// `Outbox.unreadableEntryCount` is: per-entry leniency keeps the rest of
    /// the log readable, but a silently shorter audit trail is indistinguishable
    /// from one that legitimately had fewer records, and that is precisely the
    /// state an audit trail may not be in.
    public private(set) var unreadableLabelReasonCount = 0

    /// The key of the most recent reason shard that was present but did not
    /// parse as a list of records at all — the document-level counterpart of
    /// the count above, and the same distinction `OutboxQueueCodec.Load`
    /// draws between "one row I cannot read" and "no queue at all".
    public private(set) var unreadableLabelReasonKey: String?

    public func labelReasons(accountID: String, threadID: String? = nil) -> [LabelReason] {
        let months = load([String].self, DocumentKeys.labelReasonMonths(accountID: accountID)) ?? []
        var found: [LabelReason] = []
        let now = Date()
        for month in months {
            let key = DocumentKeys.labelReasons(accountID: accountID, month: month)
            let loaded = LabelReasonLog.load(documents.data(forKey: key),
                                             decoder: decoder, now: now)
            unreadableLabelReasonCount += loaded.unreadableEntryCount
            if loaded.documentUnreadable { unreadableLabelReasonKey = key }
            found.append(contentsOf: loaded.entries)
        }
        if let threadID { found = found.filter { $0.threadID == threadID } }
        return found.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Appends to the month shard the record's own timestamp lands in.
    ///
    /// Throws — leaving the shard's bytes exactly as they were — when the
    /// existing document does not parse; see `LabelReasonLog`'s decode rule for
    /// why a write is strict where a read is lenient.
    public func recordLabelReason(_ reason: LabelReason, accountID: String) throws {
        let month = MonthShard.key(for: reason.recordedAt)
        let key = DocumentKeys.labelReasons(accountID: accountID, month: month)
        let updated = try LabelReasonLog.appended(reason, to: documents.data(forKey: key),
                                                  key: key, encoder: encoder,
                                                  decoder: decoder, now: reason.recordedAt)
        documents.setData(updated, forKey: key)
        try registerLabelReasonMonth(month, accountID: accountID)
    }

    /// The reason log's own month registry. Separate from `registerMonth`'s
    /// because a reason can be recorded for a thread whose month shard the
    /// account never registered (an archive-search hit six months back), and a
    /// purge that looked only at `indexMonths` would then miss the reason shard.
    private func registerLabelReasonMonth(_ month: String, accountID: String) throws {
        let key = DocumentKeys.labelReasonMonths(accountID: accountID)
        var months = try loadStrict([String].self, key) ?? []
        guard !months.contains(month) else { return }
        months.append(month)
        try save(months, key)
    }

    // MARK: IMAP mailbox directory

    public func imapMailboxDirectory(accountID: String) -> IMAPMailboxDirectory? {
        load(IMAPMailboxDirectory.self, DocumentKeys.imapMailboxes(accountID: accountID))
    }

    public func saveIMAPMailboxDirectory(_ directory: IMAPMailboxDirectory,
                                         accountID: String) throws {
        try save(directory, DocumentKeys.imapMailboxes(accountID: accountID))
    }

    // MARK: Bodies and labels

    public func body(messageID: String) -> MessageBody? {
        load(MessageBody.self, DocumentKeys.body(messageID))
    }

    /// `accountID` is required so the body can be registered for purging.
    /// Walking index rows into thread documents is NOT sufficient to find
    /// every body at sign-out: if the thread write failed (or the thread was
    /// later removed) after the body landed, that body has no path leading to
    /// it and would survive sign-out — mail still readable on disk after the
    /// user disconnected the account, which is the exact thing `purge` exists
    /// to prevent. The registry below is written FIRST, so a body is
    /// discoverable before it exists rather than after.
    public func saveBody(_ body: MessageBody, accountID: String) throws {
        try registerBody(body.messageID, accountID: accountID)
        try save(body, DocumentKeys.body(body.messageID))
    }

    private func registerBody(_ messageID: String, accountID: String) throws {
        let key = DocumentKeys.bodyIndex(accountID: accountID)
        var ids = try loadStrict([String].self, key) ?? []
        guard !ids.contains(messageID) else { return }
        ids.append(messageID)
        try save(ids, key)
    }

    public func labels(accountID: String) -> [MailLabel] {
        load([MailLabel].self, DocumentKeys.labels(accountID: accountID)) ?? []
    }

    public func saveLabels(_ labels: [MailLabel], accountID: String) throws {
        try save(labels, DocumentKeys.labels(accountID: accountID))
    }
}
