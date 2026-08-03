import Foundation
import Observation

/// Backs every HUD surface. Owns selection and the loaded summary window;
/// mutations (read/archive/etc.) apply to the store immediately so the UI
/// never waits on the network — the outbox carries the change to the
/// provider separately.
@MainActor @Observable public final class RavenViewModel {
    private let store: MailStore
    /// Where the mark-read mutation `select(_:)` applies locally also gets
    /// queued for the provider. Optional so call sites (and this file's own
    /// tests) that only care about the local list/selection behaviour don't
    /// need a live `Outbox` — `nil` simply means the local mutation is never
    /// synced, matching the pre-fix behaviour.
    private let outbox: Outbox?
    public var searchText = ""
    public private(set) var summaries: [ThreadSummary] = []
    public private(set) var selectedThread: MailThread?
    public var accountID: String?

    public init(store: MailStore, outbox: Outbox? = nil) {
        self.store = store
        self.outbox = outbox
        self.accountID = store.accounts().first?.id
    }

    /// `ThreadSearch.match` only ever filters the loaded window (see
    /// `ThreadSearch`'s own documentation) — `from:` matches the sender's
    /// address, never their display name, and a bare term never matches a
    /// participant. Callers presenting this list must not imply broader
    /// coverage than that.
    public var visibleThreads: [ThreadSummary] {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? summaries
            : ThreadSearch.match(summaries, query: searchText)
    }

    public func reload() {
        guard let accountID else { summaries = []; return }
        let calendar = Calendar(identifier: .gregorian)
        let months = (0..<4).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: Date()).map(MonthShard.key(for:))
        }
        summaries = store.summaries(accountID: accountID, months: months)
        // The selection can point at a thread that just left the window (e.g.
        // archived out from under it); re-resolve so stale detail doesn't
        // linger next to a list that no longer contains it.
        if let selectedThread, store.thread(selectedThread.id) == nil {
            self.selectedThread = nil
        }
    }

    public func select(_ threadID: String) {
        guard var thread = store.thread(threadID) else { selectedThread = nil; return }
        let wasUnread = thread.messages.contains { !$0.isRead }
        // Opening a thread reads it. Apply it locally first so the row
        // updates on the same frame, then queue the SAME mutation on the
        // outbox so it actually reaches the provider — local-first still
        // means eventually-synced, exactly like `RavenMCPOperations.mutate`'s
        // archive/star/label operations. Only enqueued when something was
        // actually unread, so re-selecting an already-read thread doesn't
        // queue a no-op mutation.
        for index in thread.messages.indices where !thread.messages[index].isRead {
            thread.messages[index].isRead = true
            thread.messages[index].labelIDs.removeAll { $0 == "UNREAD" }
        }
        try? store.upsertThread(thread)
        if wasUnread {
            try? outbox?.enqueue(.labels(LabelMutation(threadIDs: [threadID], remove: ["UNREAD"])))
        }
        selectedThread = thread
        reload()
    }

    public func clearSelection() {
        selectedThread = nil
    }

    public func body(for message: MailMessage) -> MessageBody? {
        store.body(messageID: message.id)
    }
}
