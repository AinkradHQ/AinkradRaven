import Foundation
import AinkradAppKit

/// Applies the saved `RuleSet` to threads a delta sync just discovered — NOT
/// retroactively to the whole store. `RavenRuntime.syncAccount` calls this
/// with exactly the ids `SyncEngine.syncDelta` fetched/upserted this pass
/// (`delta.changedThreadIDs`, filtered to the ones that actually landed), so a
/// rule saved today never reaches back through months of already-synced mail
/// — only what arrives from here on.
@MainActor public enum RuleEngine {
    /// Runs `rules` in order against each of `threadIDs`, stopping at the
    /// first matching rule per thread whose `stopProcessing` is set — every
    /// OTHER matching rule for that thread still runs first, in order, until
    /// one says stop or the list is exhausted. Each match's action goes
    /// through `ThreadMutationApplier.applyLocally` (so the store reflects it
    /// immediately) and `outbox.enqueue` (so it reaches the provider) —
    /// EXACTLY the same two calls `RavenViewModel.apply` and
    /// `RavenMCPOperations.mutate` already use, never a provider call of its
    /// own. Threads unknown to the store (a delta id that failed to fetch) are
    /// skipped, not treated as a mismatch worth recording.
    public static func apply(ruleSet: RuleSet, threadIDs: [String],
                             store: MailStore, outbox: Outbox) {
        guard !ruleSet.rules.isEmpty, !threadIDs.isEmpty else { return }
        for threadID in threadIDs {
            guard let thread = store.thread(threadID) else { continue }
            let summary = thread.summary()
            for rule in ruleSet.rules {
                guard rule.matches(summary) else { continue }
                let mutation = rule.action.mutation(threadIDs: [threadID])
                ThreadMutationApplier.applyLocally(mutation, store: store)
                do {
                    try outbox.enqueue(.labels(mutation), accountID: thread.accountID)
                } catch {
                    // Local-first: the store already reflects the action.
                    // Nothing further to do here if the queue write fails —
                    // there is no UI surface for a background rule's enqueue
                    // failure, unlike a human-initiated mutation's `rowErrors`.
                }
                if rule.stopProcessing { break }
            }
        }
    }
}
