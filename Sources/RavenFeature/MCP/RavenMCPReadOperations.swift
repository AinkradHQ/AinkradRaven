import Foundation
import AinkradAppKit

/// Every **read** tool body: `list_accounts`, `list_labels`, `search_mail`,
/// `unread_summary`, `bundle_by_sender`, `read_thread`.
///
/// Split out of `RavenMCPOperations` along the seam the tool table already
/// draws — `RavenMCPServer.Tool.readOnly` — because it is a real behavioural
/// boundary and not a line-count dodge: nothing in this file takes an `Outbox`,
/// so a read tool physically cannot queue a mutation, and the one place a read
/// may touch the network (`search_mail`'s `include_archive`) is now the only
/// `providers` use in the file. `RavenMCPOperations` keeps the argument
/// decoding, the `ok`/`fail` shapes, the validated `limit`, and every path that
/// writes (mutations, drafts, send) — so "which tools can change something" is
/// answerable by reading one file's imports rather than a switch.
///
/// `run` returns `nil` for an operation that is not a read tool, which is how
/// `RavenMCPOperations.run` keeps a single dispatch point and an unknown
/// operation keeps producing exactly one error message.
enum RavenMCPReadOperations {
    /// The month keys covering the synced window, shared with the Inbox list
    /// through `UnifiedInbox.recentMonths` — a tool that searched a different
    /// span than the UI would silently disagree with it, and a magic "4 months"
    /// would drift from `SyncEngine.windowDays` the moment either changed.
    @MainActor
    private static func recentMonths() -> [String] { UnifiedInbox.recentMonths() }

    @MainActor
    static func run(_ operation: String, args: [String: Any], store: MailStore,
                    providers: MailProviderRouter?) async -> AgentActionResult? {
        let ok = RavenMCPOperations.ok
        let fail = RavenMCPOperations.fail

        switch operation {
        case "list_accounts":
            let lines = store.accounts().map { "\($0.id) — \($0.address) [\($0.state.rawValue)]" }
            return ok(lines.isEmpty ? "No accounts configured." : lines.joined(separator: "\n"))

        case "list_labels":
            let ids = RavenMCPOperations.scope(args) ?? store.accounts().map(\.id)
            guard !ids.isEmpty else { return fail("No accounts configured.") }
            // Every account's labels, each line attributed — label ids are
            // per-account (Gmail mints its own), so a merged list that dropped
            // the account would hand back ids the caller cannot act on.
            let lines = ids.flatMap { accountID in
                store.labels(accountID: accountID).map { "\(accountID) · \($0.id) — \($0.name)" }
            }
            return ok(lines.isEmpty ? "No labels synced yet." : lines.joined(separator: "\n"))

        case "search_mail":
            return await searchMail(args: args, store: store, providers: providers)

        case "unread_summary":
            let unread = UnifiedInbox.inbox(store: store,
                                            accountIDs: RavenMCPOperations.scope(args),
                                            months: recentMonths())
                .filter { $0.unreadCount > 0 }
            if unread.isEmpty {
                return ok("No unread threads in the synced window (last 90 days).")
            }
            // Grouped and ordered by `SenderBundles`, the same code
            // `bundle_by_sender` uses, so the two tools cannot disagree about
            // who a sender is or how many threads they sent.
            //
            // This replaced an inline `Dictionary(grouping:)` on the RAW
            // `participants.first?.email` sorted by count alone. Two defects
            // went with it: `Bea <b@example.test>`, `b@example.test` and
            // `B@Example.Test` were three separate senders, and — because a
            // count-only comparator leaves every tie to `Dictionary` iteration,
            // which Swift seeds per process — the breakdown came back in a
            // DIFFERENT ORDER on each run whenever two senders had the same
            // count. `SenderBundles.isBefore`'s third key closes that.
            let breakdown = SenderBundles.bundle(unread, limit: unread.count)
                .map { "\($0.sender.label): \($0.threadCount)" }
                .joined(separator: "\n")
            return ok("""
            \(unread.count) unread threads.

            By sender:
            \(breakdown)

            Threads:
            \(unread.map(describe).joined(separator: "\n"))
            """)

        case "bundle_by_sender":
            // Store only. This file cannot reach an outbox at all, and this
            // case deliberately does not read `providers` either: there is no
            // sender grouping a provider could answer that the index rows
            // cannot, so reaching the network here would buy nothing and break
            // the M0 invariant `send_draft` is the sole exception to.
            guard let limit = RavenMCPOperations.boundedLimit(args) else {
                return fail("limit must be a positive integer (max \(RavenMCPOperations.maxLimit).)")
            }
            // The same filtered, merged, windowed read `unread_summary` and
            // `search_mail` use — a bundle count that disagreed with the inbox
            // Sage was just shown would be worse than no bundling at all.
            let rows = UnifiedInbox.inbox(store: store,
                                          accountIDs: RavenMCPOperations.scope(args),
                                          months: recentMonths())
            if rows.isEmpty {
                return ok("No threads in the synced window (last 90 days) to bundle.")
            }
            return ok(SenderBundles.render(SenderBundles.bundle(rows, limit: limit),
                                           totalThreads: rows.count))

        case "read_thread":
            guard let id = args["thread_id"] as? String else { return fail("thread_id required.") }
            guard let thread = store.thread(id) else { return fail("No thread \(id) in the store.") }
            let rendered = thread.messages.map { message -> String in
                let body = store.body(messageID: message.id)?.plainText ?? "(body not synced)"
                let visible = QuoteTrimmer.split(body).visible
                return """
                From: \(message.from?.displayLabel ?? "unknown")
                Date: \(message.date.formatted(.iso8601))
                \(visible)
                """
            }
            // States the account: a reply has to go out from the mailbox that
            // received the thread, and the agent cannot know which that is
            // from the thread id alone.
            return ok("Subject: \(thread.subject)\nAccount: \(thread.accountID)\n\n"
                      + rendered.joined(separator: "\n---\n"))

        default:
            return nil
        }
    }

    @MainActor
    private static func searchMail(args: [String: Any], store: MailStore,
                                   providers: MailProviderRouter?) async -> AgentActionResult {
        let ok = RavenMCPOperations.ok
        let fail = RavenMCPOperations.fail
        let accountIDs = RavenMCPOperations.scope(args)
        let query = args["query"] as? String ?? ""
        let limit = args["limit"] as? Int ?? 25
        let includeArchive = args["include_archive"] as? Bool ?? false

        if includeArchive {
            // Reaches the full mailbox via the provider's server-side
            // search — the ONE place this tool set is allowed to touch
            // the network ahead of the store, and only because the
            // caller explicitly asked for `include_archive`. Every hit is
            // cached locally (`upsertThread`) exactly as `RavenRuntime.
            // searchArchive` does, so it becomes a normal store row
            // reachable via `read_thread`/`archive`/etc. afterward.
            guard let providers else {
                return fail("No provider attached; cannot search the archive.")
            }
            let targets = accountIDs ?? providers.attachedAccountIDs
            guard !targets.isEmpty else {
                return fail("No provider attached; cannot search the archive.")
            }
            var groups: [[ThreadSummary]] = []
            var failure: String?
            var succeeded = false
            for target in targets {
                guard let provider = providers.provider(for: target) else {
                    failure = failure ?? "no provider attached for \(target)."
                    continue
                }
                do {
                    let hits = try await provider.searchThreads(query: query, limit: limit)
                    for hit in hits { try? store.upsertThread(hit) }
                    groups.append(hits.map { $0.summary() })
                    succeeded = true
                } catch let error as MailError {
                    // Reuses `MailError`'s existing cases rather than
                    // `String(describing:)`-ing the raw error — a Gmail
                    // error body must never reach a tool response any more
                    // than it may reach `MailAccount.lastError` (see
                    // `GmailProvider.perform`'s documentation).
                    failure = failure ?? archiveErrorMessage(error)
                } catch {
                    failure = failure ?? "provider error."
                }
            }
            // Only a total failure is reported as one: if one account
            // answered, its hits are real and must not be thrown away
            // because another account was rate-limited.
            if !succeeded {
                return fail("Archive search failed: \(failure ?? "provider error.")")
            }
            let hits = Array(UnifiedInbox.merge(groups).prefix(limit))
            if hits.isEmpty {
                return ok("No matching threads in the full archive search either.")
            }
            return ok(hits.map(describe).joined(separator: "\n"))
        }

        // Filtered to the same "in the inbox" set the Inbox list and
        // `unread_summary` use — see `InboxFilter`'s documentation for
        // why these three must never disagree. A thread that left the
        // inbox is still readable via `read_thread`; it just doesn't
        // show up as an inbox search hit. This is the DEFAULT path —
        // synced-window only, exactly as the tool description promises —
        // and never touches `provider`.
        let hits = ThreadSearch.match(UnifiedInbox.inbox(store: store, accountIDs: accountIDs,
                                                        months: recentMonths()),
                                      query: query).prefix(limit)
        if hits.isEmpty {
            return ok("No matching threads in the synced window (last 90 days). " +
                      "This does not mean no such mail exists — only that it hasn't " +
                      "synced this far back, or at all. Call again with " +
                      "\"include_archive\": true to search the full mailbox.")
        }
        return ok(hits.map(describe).joined(separator: "\n"))
    }

    /// Short, user-safe text for an archive-search failure — mirrors
    /// `RavenRuntime.archiveSearchFailureMessage`'s cases so the tool and the
    /// UI agree on what "rate-limited" vs "failed" mean, without either one
    /// echoing a raw provider error body.
    private static func archiveErrorMessage(_ error: MailError) -> String {
        switch error {
        case .notAuthenticated:
            return "no account connected."
        case .rateLimited(let retryAfter):
            return "rate-limited by Gmail; try again in \(Int(retryAfter))s."
        case .providerFailed(let status, _):
            return "provider request failed (status \(status))."
        case .decodingFailed:
            return "could not decode the provider's response."
        default:
            return "provider error."
        }
    }

    /// Includes the account id: a merged multi-account list in which the rows
    /// don't say which mailbox they came from is not usable — the agent cannot
    /// reply from the right address or name the account in its answer.
    private static func describe(_ summary: ThreadSummary) -> String {
        let sender = summary.participants.first?.displayLabel ?? "unknown"
        let unread = summary.unreadCount > 0 ? " [unread]" : ""
        return "\(summary.id) · \(summary.accountID) · \(sender) · \(summary.subject)\(unread)"
    }
}
