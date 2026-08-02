import Foundation

/// One engine per account. Serial by construction — every entry point is
/// `@MainActor` and awaits the previous run, so two syncs cannot interleave
/// writes to the same index shard.
@MainActor public final class SyncEngine {
    private let store: MailStore
    private let provider: MailProvider
    private let accountID: String
    private let windowDays: Int
    public private(set) var state: SyncState = .idle

    public init(store: MailStore, provider: MailProvider,
                accountID: String, windowDays: Int = 90) {
        self.store = store
        self.provider = provider
        self.accountID = accountID
        self.windowDays = windowDays
    }

    public var windowStart: Date {
        Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -windowDays, to: Date()) ?? .distantPast
    }

    /// Newest-first page walk over the window. Thread metadata only — bodies are
    /// fetched when a thread is opened, so the list is usable immediately.
    public func backfill() async throws {
        state = .backfilling(threadsSynced: 0)
        var synced = 0
        var pageToken: String?
        do {
            repeat {
                let page = try await provider.fetchThreads(since: windowStart, pageToken: pageToken)
                for thread in page.threads {
                    try store.upsertThread(thread)
                    synced += 1
                }
                state = .backfilling(threadsSynced: synced)
                pageToken = page.nextPageToken
            } while pageToken != nil

            let labels = try await provider.fetchLabels()
            try store.saveLabels(labels, accountID: accountID)

            let cursor = try await provider.currentCursor()
            try updateAccount { account in
                account.syncCursor = cursor
                account.state = .ready
                account.lastSyncedAt = Date()
                account.lastError = nil
            }
            state = .idle
        } catch {
            try? updateAccount { account in
                account.state = .failed
                account.lastError = String(describing: error)
            }
            state = .failed(String(describing: error))
            throw error
        }
    }

    private func updateAccount(_ mutate: (inout MailAccount) -> Void) throws {
        guard var account = store.accounts().first(where: { $0.id == accountID }) else { return }
        mutate(&account)
        try store.saveAccount(account)
    }
}
