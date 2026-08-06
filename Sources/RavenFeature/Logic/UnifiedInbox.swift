import Foundation

/// The one multi-account read: index rows from several accounts, merged into a
/// single date-ordered list with each row still carrying the account it came
/// from.
///
/// Where this lives was a design decision, not an accident. `MailStore.
/// summaries(accountID:months:)` stays exactly as it is — a raw, per-account,
/// per-shard index read; that is its whole contract and widening it to take a
/// list of accounts would have pushed "which accounts, and in what order, and
/// filtered how" into every store conformer. Instead the merge is a logic type
/// over the store, so the Inbox UI and the MCP layer call one function and can
/// never answer "what's unread across my accounts" two different ways. The
/// per-row attribution needs no new model: `ThreadSummary.accountID` is
/// already there and is preserved verbatim through the merge.
///
/// `accountIDs: nil` means genuinely ALL accounts (whatever the store has),
/// which is what a caller that omitted an account id actually asked for — as
/// opposed to the M0 habit of silently substituting `accounts.first`.
public enum UnifiedInbox {
    /// Every month key covering the same window `SyncEngine` actually syncs
    /// (90 days by default), rather than an independent guess. Both the Inbox
    /// list and the MCP tools take their window from here so the two cannot
    /// disagree about how far back "the synced window" reaches; deriving it
    /// from `SyncEngine.windowStart` is what stops a magic "last 4 months"
    /// drifting away from `SyncEngine.windowDays`.
    @MainActor
    public static func recentMonths(now: Date = Date()) -> [String] {
        MonthShard.keys(from: SyncEngine.windowStart(from: now, windowDays: 90), to: now)
    }

    /// Raw merged index rows, newest first. No inbox filtering — callers that
    /// present "the inbox" use `inbox(...)` below instead.
    ///
    /// Sorted by `lastMessageDate` descending across the merged set, so two
    /// accounts interleave by date rather than appearing as one account's block
    /// followed by another's. Ties break on account id then thread id purely so
    /// the order is stable between calls.
    @MainActor
    public static func summaries(store: MailStore, accountIDs: [String]? = nil,
                                 months: [String]) -> [ThreadSummary] {
        let ids = accountIDs ?? store.accounts().map(\.id)
        return ids
            .flatMap { store.summaries(accountID: $0, months: months) }
            .sorted(by: isBefore)
    }

    /// The merged read every surface that claims to show "the inbox" uses:
    /// `InboxFilter` applied to the merge, so the Inbox list, `search_mail` and
    /// `unread_summary` agree about which threads count as inbox mail across
    /// accounts exactly as they already agreed within one account.
    @MainActor
    public static func inbox(store: MailStore, accountIDs: [String]? = nil,
                            months: [String]) -> [ThreadSummary] {
        InboxFilter.apply(summaries(store: store, accountIDs: accountIDs, months: months))
    }

    /// Merges already-loaded rows from several accounts — used where the rows
    /// did not come from a shard read (an archive search fanned out across
    /// accounts, say) but must still be presented in one date order.
    public static func merge(_ groups: [[ThreadSummary]]) -> [ThreadSummary] {
        groups.flatMap { $0 }.sorted(by: isBefore)
    }

    private static func isBefore(_ lhs: ThreadSummary, _ rhs: ThreadSummary) -> Bool {
        if lhs.lastMessageDate != rhs.lastMessageDate {
            return lhs.lastMessageDate > rhs.lastMessageDate
        }
        if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
        return lhs.id < rhs.id
    }
}
