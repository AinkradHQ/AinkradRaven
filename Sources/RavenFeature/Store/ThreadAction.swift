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

    /// The canonical `FlagMutation` this action becomes for the given thread
    /// ids. Provider-independent: it names *states*, not Gmail labels. Render
    /// it through the account's `LabelVocabulary` to get the `LabelMutation`
    /// the outbox stores and the provider applies —
    /// `GmailVocabulary().render(_:)` reproduces byte-for-byte the strings this
    /// method used to hardcode.
    ///
    /// `.label`'s explicit strings are provider labels supplied by a caller
    /// (the MCP `label` tool, a `MailRule`), so they pass through as
    /// `.user(_)` and render back unchanged.
    public func mutation(threadIDs: [String]) -> FlagMutation {
        switch self {
        case .archive:
            return FlagMutation(threadIDs: threadIDs, remove: [.inbox])
        case .trash:
            return FlagMutation(threadIDs: threadIDs, add: [.trash], remove: [.inbox])
        case .star(let starred):
            return starred ? FlagMutation(threadIDs: threadIDs, add: [.starred])
                           : FlagMutation(threadIDs: threadIDs, remove: [.starred])
        case .setRead(let read):
            return read ? FlagMutation(threadIDs: threadIDs, remove: [.unread])
                        : FlagMutation(threadIDs: threadIDs, add: [.unread])
        case .label(let add, let remove):
            return FlagMutation(threadIDs: threadIDs,
                                add: add.map { MailFlag.user($0) },
                                remove: remove.map { MailFlag.user($0) })
        }
    }

    /// Convenience: the canonical mutation already rendered for one backend.
    public func labelMutation(threadIDs: [String],
                             vocabulary: LabelVocabulary = defaultLabelVocabulary) -> LabelMutation {
        vocabulary.render(mutation(threadIDs: threadIDs))
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
    /// Labels stay STORED as the provider's own strings — no document format
    /// change — and read/starred state is derived by asking `vocabulary` what
    /// those strings mean canonically, instead of comparing them against one
    /// provider's unread label.
    @MainActor
    public static func applyLocally(_ mutation: LabelMutation, store: MailStore,
                                   vocabulary: LabelVocabulary = defaultLabelVocabulary) {
        for id in mutation.threadIDs {
            guard var thread = store.thread(id) else { continue }
            for index in thread.messages.indices {
                var labels = Set(thread.messages[index].labelIDs)
                labels.formUnion(mutation.add)
                labels.subtract(mutation.remove)
                thread.messages[index].labelIDs = Array(labels).sorted()
                let flags = vocabulary.flags(from: labels)
                thread.messages[index].isRead = !flags.contains(.unread)
                thread.messages[index].isStarred = flags.contains(.starred)
            }
            try? store.upsertThread(thread)
        }
    }
}
