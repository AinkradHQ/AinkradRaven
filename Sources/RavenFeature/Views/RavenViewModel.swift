import Foundation
import Observation

/// Backs every HUD surface. Owns selection and the loaded summary window;
/// mutations (read/archive/etc.) apply to the store immediately so the UI
/// never waits on the network — the outbox carries the change to the
/// provider separately.
@MainActor @Observable public final class RavenViewModel {
    private let store: MailStore
    public var searchText = ""
    public private(set) var summaries: [ThreadSummary] = []
    public private(set) var selectedThread: MailThread?
    public var accountID: String?

    public init(store: MailStore) {
        self.store = store
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
        // Opening a thread reads it. Do it locally first so the row updates on
        // the same frame; the outbox carries the change to the server.
        for index in thread.messages.indices where !thread.messages[index].isRead {
            thread.messages[index].isRead = true
            thread.messages[index].labelIDs.removeAll { $0 == "UNREAD" }
        }
        try? store.upsertThread(thread)
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
