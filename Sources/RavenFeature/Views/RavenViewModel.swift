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
    /// synced, matching the pre-fix behaviour. Typed as `MutationOutbox`
    /// rather than the concrete `Outbox` so tests can inject a fake that
    /// fails `enqueue` on demand — see that protocol's documentation.
    private let outbox: (any MutationOutbox)?
    public var searchText = ""
    public private(set) var summaries: [ThreadSummary] = []
    public private(set) var selectedThread: MailThread?
    public var accountID: String?
    /// The most recent sync/backfill failure, mirrored in from
    /// `RavenRuntime.lastSyncError` so the Inbox can tell "sync failed" apart
    /// from "nothing synced yet" (see `InboxSurface`'s empty-state logic).
    /// `nil` does not mean sync has never failed — only that the most recent
    /// attempt (or the current account's initial sync) did not.
    public var lastSyncError: String?

    /// The row keyboard navigation (`j`/`k`) currently sits on — a real
    /// concept distinct from `selectedThread` (which opens the detail pane)
    /// and from SwiftUI's own list highlighting, so a keyboard action and a
    /// mouse click always agree on which row they're acting on.
    public private(set) var focusedThreadID: String?
    /// Multi-selected rows from shift/cmd-click. Empty means "no explicit
    /// multi-selection" — bulk actions then fall back to `focusedThreadID`
    /// alone, so a single focused row is still a valid action target.
    public private(set) var multiSelection: Set<String> = []
    /// Per-thread mutation failures. A failed enqueue never reverts the local
    /// change (which already happened, honestly, before the network was
    /// asked) — it surfaces here so the row can render a problem badge
    /// instead of a modal, and so nothing lies about the mutation having
    /// synced. Cleared for a thread the next time a mutation targeting it
    /// succeeds.
    public private(set) var rowErrors: [String: String] = [:]

    public init(store: MailStore, outbox: (any MutationOutbox)? = nil) {
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
        summaries = InboxFilter.apply(store.summaries(accountID: accountID, months: months))
        // The selection can point at a thread that just left the window (e.g.
        // archived out from under it); re-resolve so stale detail doesn't
        // linger next to a list that no longer contains it.
        if let selectedThread, store.thread(selectedThread.id) == nil {
            self.selectedThread = nil
        }
        let visibleIDs = Set(visibleThreads.map(\.id))
        if let focusedThreadID, !visibleIDs.contains(focusedThreadID) {
            self.focusedThreadID = nil
        }
        multiSelection.formIntersection(visibleIDs)
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

    // MARK: Keyboard focus & selection

    /// Moves `focusedThreadID` by `delta` rows through `visibleThreads`,
    /// wrapping at either end — `j`/`k` never dead-end at the top or bottom
    /// of the list. Starting from no focus lands on the first row moving
    /// forward, or the last row moving backward, so the very first `j`/`k`
    /// press always lands on something visible.
    public func moveFocus(by delta: Int) {
        let ids = visibleThreads.map(\.id)
        guard !ids.isEmpty else { focusedThreadID = nil; return }
        guard let current = focusedThreadID, let index = ids.firstIndex(of: current) else {
            focusedThreadID = delta >= 0 ? ids.first : ids.last
            return
        }
        let count = ids.count
        let next = ((index + delta) % count + count) % count
        focusedThreadID = ids[next]
    }

    /// A mouse click on a row. `shift` extends the multi-selection from the
    /// last focused row through `threadID`; `command` toggles `threadID` into
    /// (or out of) the multi-selection. Plain click clears any
    /// multi-selection and opens the thread exactly as `select(_:)` already
    /// did — clicking a row is still "open it", not "start a selection".
    public func clickRow(_ threadID: String, shift: Bool, command: Bool) {
        let ids = visibleThreads.map(\.id)
        if shift, let anchor = focusedThreadID,
           let anchorIndex = ids.firstIndex(of: anchor), let clickIndex = ids.firstIndex(of: threadID) {
            let range = anchorIndex <= clickIndex ? anchorIndex...clickIndex : clickIndex...anchorIndex
            multiSelection = Set(ids[range])
            focusedThreadID = threadID
        } else if command {
            if multiSelection.isEmpty, let anchor = focusedThreadID { multiSelection = [anchor] }
            if multiSelection.contains(threadID) { multiSelection.remove(threadID) }
            else { multiSelection.insert(threadID) }
            focusedThreadID = threadID
        } else {
            multiSelection = []
            focusedThreadID = threadID
            select(threadID)
        }
    }

    /// Makes it obvious how to clear a multi-selection — a Clear button in
    /// the selection-count bar calls straight through to this.
    public func clearMultiSelection() {
        multiSelection = []
    }

    /// The thread ids the next bulk/keyboard action should target: the
    /// explicit multi-selection if there is one, otherwise the single
    /// focused row (if any), otherwise nothing.
    public var activeThreadIDs: [String] {
        multiSelection.isEmpty
            ? focusedThreadID.map { [$0] } ?? []
            : Array(multiSelection)
    }

    // MARK: Mutations shared with `RavenMCPOperations` via `ThreadAction`

    public func archiveActive() { apply(.archive) }
    public func trashActive() { apply(.trash) }
    public func starActive(_ starred: Bool) { apply(.star(starred)) }
    public func setReadActive(_ read: Bool) { apply(.setRead(read)) }

    /// `e` and the row archive button both call this.
    public func archive(_ threadIDs: [String]) { apply(.archive, ids: threadIDs) }
    public func trash(_ threadIDs: [String]) { apply(.trash, ids: threadIDs) }
    public func star(_ threadIDs: [String], starred: Bool) { apply(.star(starred), ids: threadIDs) }
    public func setRead(_ threadIDs: [String], read: Bool) { apply(.setRead(read), ids: threadIDs) }

    /// `u` and the per-row unread toggle. Flips to unread if every targeted
    /// thread is currently read, otherwise flips every targeted thread to
    /// read — mirroring the common "select a batch, one keystroke" mail
    /// client convention rather than toggling each thread independently
    /// (which would leave a mixed-read selection in an unpredictable state).
    public func toggleUnreadActive() {
        let ids = activeThreadIDs
        guard !ids.isEmpty else { return }
        let anyUnread = ids.contains { store.thread($0)?.unreadCount ?? 0 > 0 }
        apply(.setRead(anyUnread), ids: ids)
    }

    private func apply(_ action: ThreadAction) { apply(action, ids: activeThreadIDs) }

    /// Applies one `ThreadAction` to `ids` as a SINGLE `LabelMutation` — the
    /// store update and, where an outbox is attached, exactly ONE outbox
    /// entry carrying every id, never one entry per thread. Local-first: the
    /// store already reflects the change before `enqueue` is even attempted,
    /// so a failed enqueue below never has to undo anything — it only has to
    /// say so.
    private func apply(_ action: ThreadAction, ids: [String]) {
        guard !ids.isEmpty else { return }
        let mutation = action.mutation(threadIDs: ids)
        ThreadMutationApplier.applyLocally(mutation, store: store)
        reload()
        for id in ids { rowErrors.removeValue(forKey: id) }
        do {
            try outbox?.enqueue(.labels(mutation))
        } catch {
            let message = String(describing: error)
            for id in ids { rowErrors[id] = message }
        }
    }
}
