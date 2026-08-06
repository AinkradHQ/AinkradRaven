import Foundation

/// Grouping inbox rows by who sent them, in one place.
///
/// `unread_summary` already emits a by-sender breakdown, but it does so inline
/// with `Dictionary(grouping:) { $0.participants.first?.email ?? "unknown" }`,
/// which groups on the RAW email string. That makes `Bea <b@example.test>`,
/// `b@example.test` and `B@Example.Test` three separate senders, and it puts a
/// thread with no sender at all in a bucket named by a bare string that a real
/// address could in principle collide with. Sage has to reconstruct the real
/// grouping from that output; `bundle_by_sender` gives it the grouping directly.
///
/// This type reads nothing. It is a pure function over already-loaded
/// `ThreadSummary` rows, so the tool that calls it cannot reach a provider even
/// by accident — the store read happens in `RavenMCPOperations` through
/// `UnifiedInbox`, exactly like `unread_summary`'s.
public enum SenderBundles {
    /// Who a bundle belongs to.
    ///
    /// A DISTINCT case for "no sender" rather than a reserved string: a thread
    /// whose index row carries no participant must still be countable — dropping
    /// it would make the bundle counts disagree with the thread total Sage sees
    /// from `unread_summary` — and a sentinel like `"unknown"` is a value a
    /// (malformed) address field could actually hold, which would silently merge
    /// real mail into the unknown bucket.
    public enum Sender: Equatable, Hashable, Sendable {
        /// Lowercased, display-name-stripped address.
        case address(String)
        case unknown

        /// The wire label. Parenthesised and spaced so it cannot be mistaken
        /// for an address: no RFC 5322 addr-spec contains a space or a paren.
        public var label: String {
            switch self {
            case .address(let address): return address
            case .unknown: return "(unknown sender)"
            }
        }

        /// The final tie-break key, which makes the bundle order TOTAL.
        ///
        /// Prefixed rather than raw so `.unknown` can never compare equal to
        /// any `.address`, however malformed that address is. Bundle senders are
        /// unique by construction, so distinct bundles always have distinct
        /// sort keys and the ordering cannot vary between runs.
        var sortKey: String {
            switch self {
            case .address(let address): return "0\(address)"
            case .unknown: return "1"
            }
        }
    }

    /// How many of a bundle's threads came from one account.
    ///
    /// Per-account attribution is on the bundle rather than being implied by
    /// scoping the whole call to one account: with `account_id` omitted a read
    /// spans every account (the multi-account read default), and one
    /// correspondent legitimately writes to two mailboxes. A bundle that only
    /// reported a total would tell Sage "6 threads from b@example.test" with no
    /// way to know which mailbox to reply from.
    public struct AccountTally: Equatable, Sendable {
        public let accountID: String
        public let count: Int
    }

    /// Named `SenderBundle` rather than the shorter `Bundle` the namespace
    /// would allow: a nested `Bundle` shadows `Foundation.Bundle` for every
    /// expression inside this type, which is harmless here and quietly hostile
    /// at the first call site that needs both.
    public struct SenderBundle: Equatable, Sendable {
        public let sender: Sender
        /// Threads in this bundle, newest first.
        public let threadIDs: [String]
        /// Sorted by account id, so the attribution is deterministic too.
        public let accounts: [AccountTally]
        public let threadCount: Int
        public let unreadThreadCount: Int
        public let newestDate: Date

        public var accountIDs: [String] { accounts.map(\.accountID) }
    }

    /// The grouping key for one index row.
    ///
    /// `participants.first` is the sender for these rows — the same field
    /// `RavenMCPOperations.describe` and `unread_summary` already treat as the
    /// sender. Normalisation is two steps, and both are needed:
    ///
    /// - Display names are stripped. `MailAddress.email` is *usually* already
    ///   bare, but `MailAddress(rfc5322:)` is not the only way a row is built
    ///   (a provider mapping can put a whole `Name <addr>` string in `email`),
    ///   and re-parsing costs nothing.
    /// - Case is folded. The domain is case-insensitive by RFC 5321 and no mail
    ///   provider in practice distinguishes local parts by case, so `B@X` and
    ///   `b@x` are one correspondent. Folding is `lowercased()`, not a
    ///   locale-sensitive fold, so the result cannot vary with the user's locale.
    public static func sender(of summary: ThreadSummary) -> Sender {
        guard let first = summary.participants.first else { return .unknown }
        return sender(of: first)
    }

    public static func sender(of address: MailAddress) -> Sender {
        var raw = address.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("<"), let reparsed = MailAddress(rfc5322: raw) {
            raw = reparsed.email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty else { return .unknown }
        return .address(raw.lowercased())
    }

    /// Bundles `summaries`, most threads first.
    ///
    /// The order is `threadCount` descending, then `newestDate` descending,
    /// then `Sender.sortKey` ascending. The third key is what makes it total:
    /// two senders with the same thread count and the same newest date are
    /// otherwise ordered by whatever `Dictionary` iteration produced, which
    /// varies between runs (Swift seeds its hashing per process) and would make
    /// a Sage loop over "the top N senders" non-reproducible.
    ///
    /// `limit` bounds the number of BUNDLES returned, not threads: the caller
    /// asked for the top senders, and truncating threads would understate the
    /// counts of the bundles that survive. Validation of `limit` is the
    /// boundary's job (`RavenMCPOperations`), so it is a precondition here.
    public static func bundle(_ summaries: [ThreadSummary], limit: Int) -> [SenderBundle] {
        var grouped: [Sender: [ThreadSummary]] = [:]
        for summary in summaries { grouped[sender(of: summary), default: []].append(summary) }

        let bundles = grouped.map { sender, rows -> SenderBundle in
            // Newest first, then thread id. The id arm is not decoration: a
            // bulk sender routinely produces several threads whose
            // `lastMessageDate` lands in the same second, and `Array.sorted(by:)`
            // is NOT documented as stable — so without it the thread order
            // inside a bundle could differ between runs even though the bundle
            // order is total. Exercised by
            // `SenderBundlesTests.threadOrderTieBreaksOnID`.
            let byDate = rows.sorted {
                $0.lastMessageDate != $1.lastMessageDate
                    ? $0.lastMessageDate > $1.lastMessageDate
                    : $0.id < $1.id
            }
            var perAccount: [String: Int] = [:]
            for row in byDate { perAccount[row.accountID, default: 0] += 1 }
            return SenderBundle(
                sender: sender,
                threadIDs: byDate.map(\.id),
                accounts: perAccount.keys.sorted().map {
                    AccountTally(accountID: $0, count: perAccount[$0] ?? 0)
                },
                threadCount: byDate.count,
                unreadThreadCount: byDate.filter { $0.unreadCount > 0 }.count,
                // `byDate` is non-empty: it exists only because a row was
                // appended to it. `reduce` rather than `byDate[0]` regardless,
                // so this stays total even if that ever stops being true.
                newestDate: byDate.reduce(Date.distantPast) { max($0, $1.lastMessageDate) })
        }

        return Array(bundles.sorted(by: isBefore).prefix(max(0, limit)))
    }

    static func isBefore(_ lhs: SenderBundle, _ rhs: SenderBundle) -> Bool {
        if lhs.threadCount != rhs.threadCount { return lhs.threadCount > rhs.threadCount }
        if lhs.newestDate != rhs.newestDate { return lhs.newestDate > rhs.newestDate }
        return lhs.sender.sortKey < rhs.sender.sortKey
    }

    /// The tool's response text.
    ///
    /// Every bundle states its accounts, because the whole point of spanning
    /// accounts by default is that Sage still knows which mailbox each thread
    /// lives in — the same reason `RavenMCPOperations.describe` prints the
    /// account id on every thread line.
    public static func render(_ bundles: [SenderBundle], totalThreads: Int) -> String {
        let lines = bundles.map { bundle -> String in
            let accounts = bundle.accounts
                .map { "\($0.accountID)=\($0.count)" }
                .joined(separator: ", ")
            return "\(bundle.sender.label) · \(bundle.threadCount) thread(s), "
                + "\(bundle.unreadThreadCount) unread · newest "
                + "\(bundle.newestDate.formatted(.iso8601)) · accounts \(accounts) · "
                + "threads \(bundle.threadIDs.joined(separator: ", "))"
        }
        return "\(bundles.count) sender(s) over \(totalThreads) thread(s) in the synced "
            + "window (last 90 days), most threads first.\n\n"
            + lines.joined(separator: "\n")
    }
}
