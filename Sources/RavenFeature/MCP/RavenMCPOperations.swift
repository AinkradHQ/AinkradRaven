import Foundation
import AinkradAppKit

/// Every tool body. Takes a store and an outbox — deliberately no provider, so
/// a tool physically cannot reach the network ahead of the store.
public enum RavenMCPOperations {
    private static func decode(_ arguments: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
    }

    private static func ok(_ text: String) -> AgentActionResult {
        AgentActionResult(text: text, isError: false)
    }

    private static func fail(_ text: String) -> AgentActionResult {
        AgentActionResult(text: text, isError: true)
    }

    /// Every month key covering the same window `SyncEngine` actually syncs
    /// (90 days by default), rather than an independent guess. Derived from
    /// `SyncEngine.windowStart` on purpose: a tool that searched a different
    /// span than what was synced would silently disagree with the store, and
    /// a magic "4 months" here would drift out of sync with `SyncEngine`'s
    /// `windowDays` the moment either one changed.
    @MainActor
    private static func recentMonths() -> [String] {
        let now = Date()
        let start = SyncEngine.windowStart(from: now, windowDays: 90)
        return MonthShard.keys(from: start, to: now)
    }

    @MainActor
    public static func run(_ operation: String, arguments: String,
                           store: MailStore, outbox: Outbox) async -> AgentActionResult {
        let args = decode(arguments)

        switch operation {
        case "list_accounts":
            let lines = store.accounts().map { "\($0.id) — \($0.address) [\($0.state.rawValue)]" }
            return ok(lines.isEmpty ? "No accounts configured." : lines.joined(separator: "\n"))

        case "list_labels":
            guard let accountID = args["account_id"] as? String
                    ?? store.accounts().first?.id else { return fail("No account.") }
            let labels = store.labels(accountID: accountID)
            return ok(labels.map { "\($0.id) — \($0.name)" }.joined(separator: "\n"))

        case "search_mail":
            guard let accountID = args["account_id"] as? String
                    ?? store.accounts().first?.id else { return fail("No account.") }
            let query = args["query"] as? String ?? ""
            let limit = args["limit"] as? Int ?? 25
            let hits = ThreadSearch.match(store.summaries(accountID: accountID,
                                                          months: recentMonths()),
                                          query: query).prefix(limit)
            if hits.isEmpty {
                return ok("No matching threads in the synced window (last 90 days). " +
                          "This does not mean no such mail exists — only that it hasn't " +
                          "synced this far back, or at all.")
            }
            return ok(hits.map(describe).joined(separator: "\n"))

        case "unread_summary":
            guard let accountID = args["account_id"] as? String
                    ?? store.accounts().first?.id else { return fail("No account.") }
            let unread = store.summaries(accountID: accountID, months: recentMonths())
                .filter { $0.unreadCount > 0 }
            if unread.isEmpty {
                return ok("No unread threads in the synced window (last 90 days).")
            }
            let bySender = Dictionary(grouping: unread) {
                $0.participants.first?.email ?? "unknown"
            }
            let breakdown = bySender
                .sorted { $0.value.count > $1.value.count }
                .map { "\($0.key): \($0.value.count)" }
                .joined(separator: "\n")
            return ok("""
            \(unread.count) unread threads.

            By sender:
            \(breakdown)

            Threads:
            \(unread.map(describe).joined(separator: "\n"))
            """)

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
            return ok("Subject: \(thread.subject)\n\n" + rendered.joined(separator: "\n---\n"))

        case "archive", "trash", "set_read", "star", "label":
            return await mutate(operation, args: args, store: store, outbox: outbox)

        case "create_draft":
            guard let to = (args["to"] as? [String])?.compactMap({ MailAddress(rfc5322: $0) }),
                  !to.isEmpty else { return fail("to required.") }
            let draft = OutgoingMessage(
                to: to,
                cc: (args["cc"] as? [String] ?? []).compactMap { MailAddress(rfc5322: $0) },
                subject: args["subject"] as? String ?? "",
                bodyText: args["body"] as? String ?? "",
                inReplyToMessageID: args["in_reply_to"] as? String,
                threadID: args["thread_id"] as? String)
            do {
                let id = try DraftBox.shared.save(draft)
                return ok("Draft \(id) created and visible in Compose. Call send_draft to send it.")
            } catch {
                return fail("Could not save draft: \(error)")
            }

        case "send_draft":
            guard let id = args["draft_id"] as? String else { return fail("draft_id required.") }
            guard let draft = DraftBox.shared.draft(id) else {
                return fail("No draft \(id) exists. Drafts are held in memory only and do not " +
                            "survive a restart, so this id may be stale — call create_draft " +
                            "again rather than retrying send_draft with the same id.")
            }
            // `SendAttempt` owns the whole decision: queue, drain, classify
            // the entry's real fate, and destroy the draft ONLY on a genuine
            // success. Overclaiming here is the one mistake in this tool set
            // that is unrecoverable — the draft text is gone and the user is
            // told mail went out that didn't. The human Send button in
            // `ComposeSurface` calls exactly this function, so the two paths
            // cannot disagree about what "sent" means.
            let result: SendAttempt.Result
            do {
                result = try await SendAttempt.send(draft, draftID: id, outbox: outbox,
                                                    store: store, drain: outbox.drain)
            } catch {
                return fail("Could not queue send: \(error)")
            }
            // A still-queued send is reported without `isError`: nothing went
            // wrong, it simply hasn't gone out yet.
            if case .queued = result.outcome { return ok(result.message) }
            return result.isSent ? ok(result.message) : fail(result.message)

        default:
            return fail("Unknown operation \(operation).")
        }
    }

    @MainActor
    private static func mutate(_ operation: String, args: [String: Any],
                               store: MailStore, outbox: Outbox) async -> AgentActionResult {
        guard let ids = args["thread_ids"] as? [String], !ids.isEmpty else {
            return fail("thread_ids required.")
        }
        let action: ThreadAction
        switch operation {
        case "archive": action = .archive
        case "trash":   action = .trash
        case "star":    action = .star(true)
        case "set_read":
            action = .setRead(args["read"] as? Bool ?? true)
        case "label":
            action = .label(add: args["add"] as? [String] ?? [],
                            remove: args["remove"] as? [String] ?? [])
        default:
            return fail("Unknown mutation \(operation).")
        }
        let mutation = action.mutation(threadIDs: ids)

        // Local-first: the store changes now, the provider catches up. Shared
        // with `RavenViewModel` via `ThreadMutationApplier` so the two
        // surfaces can never disagree about what "archive"/"star"/etc. means
        // to the store.
        ThreadMutationApplier.applyLocally(mutation, store: store)
        do {
            try outbox.enqueue(.labels(mutation))
        } catch {
            return fail("Applied locally but could not queue: \(error)")
        }
        return ok("\(operation) applied to \(ids.count) thread(s); queued for sync.")
    }

    private static func describe(_ summary: ThreadSummary) -> String {
        let sender = summary.participants.first?.displayLabel ?? "unknown"
        let unread = summary.unreadCount > 0 ? " [unread]" : ""
        return "\(summary.id) · \(sender) · \(summary.subject)\(unread)"
    }
}
