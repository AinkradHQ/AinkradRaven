import Foundation

/// One engine per account. Serial by construction — every entry point is
/// `@MainActor` and awaits the previous run, so two syncs cannot interleave
/// writes to the same index shard.
@MainActor public final class SyncEngine {
    /// Upper bound on pages walked in a single `backfill()`. Gmail's threads.list
    /// (and every provider we expect to add) pages at up to 100 threads per page,
    /// so 200 pages bounds one backfill at ~20,000 threads — comfortably above
    /// any real mailbox's 90-day volume — while still guaranteeing the loop
    /// terminates even against a malformed or hostile provider that never stops
    /// returning a `nextPageToken`.
    public static let maxBackfillPages = 200

    private let store: MailStore
    private let provider: MailProvider
    private let accountID: String
    private let windowDays: Int
    private let maxPages: Int
    public private(set) var state: SyncState = .idle
    /// Set when the page cap (or a repeated page token) cut a backfill short.
    /// Checked by callers/UI that want to surface "sync stopped early" rather
    /// than silently reporting a clean completion.
    public private(set) var lastBackfillTruncated = false

    public init(store: MailStore, provider: MailProvider,
                accountID: String, windowDays: Int = 90,
                maxBackfillPages: Int = SyncEngine.maxBackfillPages) {
        self.store = store
        self.provider = provider
        self.accountID = accountID
        self.windowDays = windowDays
        self.maxPages = maxBackfillPages
    }

    /// Pinned to UTC to match `MonthShard`'s convention — the results of this
    /// window feed straight into UTC-keyed month shards, so a local-time
    /// boundary here would disagree with where threads actually get filed.
    static func windowStart(from now: Date, windowDays: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(byAdding: .day, value: -windowDays, to: now) ?? .distantPast
    }

    public var windowStart: Date {
        Self.windowStart(from: Date(), windowDays: windowDays)
    }

    /// Newest-first page walk over the window. Thread metadata only — bodies are
    /// fetched when a thread is opened, so the list is usable immediately.
    ///
    /// Bounded by `maxPages` and by same-token detection: a provider that
    /// hands back the exact token it was just given is cycling, not making
    /// slow progress, so the walk stops immediately rather than spinning the
    /// main actor forever.
    public func backfill() async throws {
        state = .backfilling(threadsSynced: 0)
        lastBackfillTruncated = false
        var synced = 0
        var pageToken: String?
        var pagesFetched = 0
        do {
            repeat {
                let requestedToken = pageToken
                let page = try await provider.fetchThreads(since: windowStart, pageToken: pageToken)
                for thread in page.threads {
                    try store.upsertThread(thread)
                    synced += 1
                }
                pagesFetched += 1
                state = .backfilling(threadsSynced: synced)

                if let next = page.nextPageToken, next == requestedToken {
                    // The provider echoed back the token we just sent it —
                    // a definite cycle, not slow progress. Stop now.
                    lastBackfillTruncated = true
                    pageToken = nil
                } else if page.nextPageToken != nil && pagesFetched >= maxPages {
                    lastBackfillTruncated = true
                    pageToken = nil
                } else {
                    pageToken = page.nextPageToken
                }
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

    /// Incremental sync. Falls back to a full backfill when there is no cursor
    /// or the provider rejects the one we hold — a cursor that is too old is a
    /// normal event after the app has been closed for a while, not an error.
    public func syncDelta() async throws {
        guard let cursor = store.accounts().first(where: { $0.id == accountID })?.syncCursor else {
            try await backfill()
            return
        }
        state = .delta
        let delta: MailDelta
        do {
            delta = try await provider.fetchDelta(cursor: cursor)
        } catch {
            state = .idle
            try await backfill()
            return
        }

        for id in delta.changedThreadIDs {
            // A thread can vanish between the delta listing it and us fetching
            // it. That is not a sync failure; skip it and keep going.
            guard let thread = try? await provider.fetchThread(id: id) else { continue }
            try store.upsertThread(thread)
        }
        for id in delta.removedThreadIDs {
            guard let existing = store.thread(id) else { continue }
            try store.removeThread(id, accountID: accountID, date: existing.lastMessageDate)
        }

        try updateAccount { account in
            account.syncCursor = delta.newCursor
            account.lastSyncedAt = Date()
            account.lastError = nil
            account.state = .ready
        }
        state = .idle
    }

    private func updateAccount(_ mutate: (inout MailAccount) -> Void) throws {
        guard var account = store.accounts().first(where: { $0.id == accountID }) else { return }
        mutate(&account)
        try store.saveAccount(account)
    }
}
