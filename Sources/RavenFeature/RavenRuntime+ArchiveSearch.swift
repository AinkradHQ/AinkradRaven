import Foundation
import AinkradAppKit

/// Result of a deliberate "search all mail" act — see `RavenRuntime.
/// searchArchive`. Distinct `.results([])` vs `.failed` on purpose: a remote
/// search that genuinely found nothing must never look the same as one that
/// couldn't run at all (rate-limited, unauthenticated, transport failure).
public enum ArchiveSearchState: Equatable {
    case idle
    case searching
    case results([ThreadSummary])
    case failed(String)
}

/// Searching Gmail's full archive, outside the locally-synced window.
///
/// The cleanest seam in the runtime: it owns exactly one piece of published
/// state (`archiveSearchState`), reaches the network only through
/// `providers`, and nothing else in the runtime calls into it. `clearArchiveSearch`
/// is the only other writer of that state and lives here with it.
extension RavenRuntime {

    /// A deliberate, explicit "search all mail" act — never triggered per
    /// keystroke. Delegates to the provider's server-side search
    /// (`MailProvider.searchThreads`), which reaches Gmail's full archive,
    /// not just the locally-synced window `ThreadSearch` filters.
    ///
    /// Every hit is cached locally via `store.upsertThread` so the thread
    /// becomes a normal store row from then on — it opens, renders, and can
    /// be archived/replied like any synced thread, with its body still
    /// fetched lazily exactly as today. That matters because a 6-month-old
    /// hit lands in a month-shard the Inbox's windowed view (`RavenViewModel.
    /// reload`, `RavenMCPOperations.recentMonths`) never loads — caching it
    /// does NOT make it show up in the Inbox list. This is deliberate, not a
    /// gap: `archiveSearchState` is surfaced as its OWN "results from all
    /// mail" list, kept visibly separate from the Inbox's windowed view,
    /// rather than silently blending an archive hit into a list whose whole
    /// contract is "the last 90 days" — the honest presentation the task
    /// calls for. Selecting a hit from that list still works normally
    /// (`RavenViewModel.select`/`store.thread`), since `upsertThread` already
    /// made it a real row.
    ///
    /// Failure is distinguishable from an empty result: `.failed` carries a
    /// short, safe message (never Gmail's raw response body — see
    /// `GmailProvider.perform`'s documentation for why that must never reach
    /// a persisted field) while `.results([])` means the provider actually
    /// ran and genuinely found nothing.
    /// Searches one account, or — with no argument — every attached account,
    /// merging the hits into one date-ordered list via `UnifiedInbox.merge` so
    /// the results read exactly like the unified Inbox does, each row still
    /// attributed to the account it came from.
    ///
    /// With several accounts, `.failed` means EVERY account that was asked
    /// failed. If one account answers and another errors, the answer is
    /// `.results` for what was actually found — silently reporting a total
    /// failure would hide real hits, and reporting a clean success would hide
    /// nothing more than the M0 single-account case already did. A search with
    /// no attached providers at all is `.failed`, not an empty result, exactly
    /// as before.
    public func searchArchive(query: String, accountID: String? = nil) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { setArchiveSearchState(.idle); return }
        let targets = accountID.map { [$0] } ?? providers.attachedAccountIDs
        guard !targets.isEmpty else {
            setArchiveSearchState(.failed(Self.archiveSearchFailureMessage(
                MailError.notAuthenticated(accountID: accountID ?? ""))))
            return
        }
        setArchiveSearchState(.searching)
        var groups: [[ThreadSummary]] = []
        var failure: String?
        var succeeded = false
        for target in targets {
            guard let provider = providers.provider(for: target) else {
                failure = failure ?? Self.archiveSearchFailureMessage(
                    MailError.notAuthenticated(accountID: target))
                continue
            }
            do {
                let threads = try await provider.searchThreads(query: trimmed, limit: 50)
                for thread in threads {
                    try? store.upsertThread(thread)
                }
                groups.append(threads.map { $0.summary() })
                succeeded = true
            } catch {
                failure = failure ?? Self.archiveSearchFailureMessage(error)
            }
        }
        if !succeeded, let failure {
            setArchiveSearchState(.failed(failure))
            return
        }
        setArchiveSearchState(.results(UnifiedInbox.merge(groups)))
    }

    /// Clears the last archive search — called when the search field itself
    /// is cleared or edited, so a stale "results from all mail" list never
    /// lingers next to a search string that no longer produced it.
    public func clearArchiveSearch() {
        setArchiveSearchState(.idle)
    }

    /// Maps a thrown error to a short, user-safe message — reusing
    /// `MailError`'s existing cases rather than `String(describing:)`-ing an
    /// arbitrary error, which for `.providerFailed` could echo a Gmail
    /// response body. Never written to `MailAccount.lastError` (that field is
    /// document-backed and persisted); this only ever feeds `archiveSearchState`.
    private static func archiveSearchFailureMessage(_ error: Error) -> String {
        switch error {
        case MailError.notAuthenticated:
            return "No account connected."
        case MailError.rateLimited(let retryAfter):
            return "Gmail rate-limited this search; try again in \(Int(retryAfter))s."
        case MailError.providerFailed(let status, _):
            return "Search all mail failed (status \(status))."
        case MailError.decodingFailed:
            return "Search all mail failed to decode the provider's response."
        default:
            return "Search all mail failed."
        }
    }
}
