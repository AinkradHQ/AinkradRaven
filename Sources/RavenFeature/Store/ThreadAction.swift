import Foundation
import AinkradAppKit

/// One local-first thread mutation, shared by every surface that can archive,
/// star, mark-read, or trash a thread — the human `RavenViewModel` and the
/// agent `RavenMCPOperations`. `RavenMCPOperations.mutate` already had this
/// exact archive/trash/star/set_read/label logic built by hand per operation
/// string; the Inbox UI needed the SAME behaviour, not a second copy that
/// could quietly drift from it (the send path already drifted once — see
/// `SendAttempt`'s documentation for why that class exists at all).
public enum ThreadAction: Equatable, Hashable, Codable, Sendable {
    case archive
    case trash
    case star(Bool)
    case setRead(Bool)
    case label(add: [String], remove: [String])

    /// The `LabelMutation` this action becomes for the given thread ids —
    /// byte-for-byte what `RavenMCPOperations.mutate` used to build inline
    /// for each MCP operation string.
    public func mutation(threadIDs: [String]) -> LabelMutation {
        switch self {
        case .archive:
            return LabelMutation(threadIDs: threadIDs, remove: ["INBOX"])
        case .trash:
            return LabelMutation(threadIDs: threadIDs, add: ["TRASH"], remove: ["INBOX"])
        case .star(let starred):
            return starred ? LabelMutation(threadIDs: threadIDs, add: ["STARRED"])
                           : LabelMutation(threadIDs: threadIDs, remove: ["STARRED"])
        case .setRead(let read):
            return read ? LabelMutation(threadIDs: threadIDs, remove: ["UNREAD"])
                        : LabelMutation(threadIDs: threadIDs, add: ["UNREAD"])
        case .label(let add, let remove):
            return LabelMutation(threadIDs: threadIDs, add: add, remove: remove)
        }
    }
}

/// Which account each of a set of thread ids belongs to.
///
/// A mutation must reach the mailbox the thread actually lives in, and with
/// several accounts connected that can no longer be inferred from "the current
/// account" — it has to be read off the thread. Shared by `RavenViewModel` and
/// `RavenMCPOperations` so the human and the agent resolve the account the same
/// way, exactly as `ThreadAction` already made them agree on what a mutation is.
public enum ThreadAccountGrouping {
    /// Groups `ids` by their thread's `accountID`. An id the store does not
    /// know is filed under `fallback` rather than dropped — dropping it would
    /// silently not sync a mutation the caller was told had been queued.
    /// Deterministically ordered by account id.
    @MainActor
    public static func group(_ ids: [String], store: MailStore,
                            fallback: String? = nil) -> [(accountID: String?, ids: [String])] {
        var byAccount: [String?: [String]] = [:]
        for id in ids {
            let accountID = store.thread(id)?.accountID ?? fallback
            byAccount[accountID, default: []].append(id)
        }
        return byAccount
            .map { (accountID: $0.key, ids: $0.value) }
            .sorted { ($0.accountID ?? "") < ($1.accountID ?? "") }
    }
}

/// Applies a `LabelMutation` to the store's local copy of every thread it
/// names. This is the exact per-thread loop `RavenMCPOperations.mutate` used
/// to own inline — moved here so both it and `RavenViewModel` call one copy.
/// Local-first: call this BEFORE `outbox.enqueue`, never after, so the row
/// updates on the same frame regardless of network state.
public enum ThreadMutationApplier {
    @MainActor
    public static func applyLocally(_ mutation: LabelMutation, store: MailStore) {
        for id in mutation.threadIDs {
            guard var thread = store.thread(id) else { continue }
            for index in thread.messages.indices {
                var labels = Set(thread.messages[index].labelIDs)
                labels.formUnion(mutation.add)
                labels.subtract(mutation.remove)
                thread.messages[index].labelIDs = Array(labels).sorted()
                thread.messages[index].isRead = !labels.contains("UNREAD")
                thread.messages[index].isStarred = labels.contains("STARRED")
            }
            try? store.upsertThread(thread)
        }
    }
}
