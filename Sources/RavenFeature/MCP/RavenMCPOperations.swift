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

    /// The month keys covering the synced window, shared with the Inbox list
    /// through `UnifiedInbox.recentMonths` — a tool that searched a different
    /// span than the UI would silently disagree with it, and a magic "4 months"
    /// would drift from `SyncEngine.windowDays` the moment either changed.
    @MainActor
    private static func recentMonths() -> [String] { UnifiedInbox.recentMonths() }

    /// The accounts a read covers: the one named by `account_id`, or EVERY
    /// account when it is omitted.
    ///
    /// Omitting `account_id` used to fall back to `store.accounts().first`,
    /// which meant "what's unread?" answered for an arbitrary mailbox and
    /// quietly ignored the rest. `nil` here means all accounts, which is what
    /// the caller actually asked for; `UnifiedInbox` does the merge so the
    /// answer matches the Inbox exactly.
    private static func scope(_ args: [String: Any]) -> [String]? {
        (args["account_id"] as? String).map { [$0] }
    }

    /// `providers` is optional and used ONLY by `search_mail`'s
    /// `include_archive` path — every other tool physically cannot reach the
    /// network ahead of the store, exactly as before. It is a router rather
    /// than a single provider because an archive search with no `account_id`
    /// must reach every connected account, not an arbitrary one.
    @MainActor
    public static func run(_ operation: String, arguments: String,
                           store: MailStore, outbox: Outbox,
                           providers: MailProviderRouter? = nil) async -> AgentActionResult {
        let args = decode(arguments)

        switch operation {
        case "list_accounts":
            let lines = store.accounts().map { "\($0.id) — \($0.address) [\($0.state.rawValue)]" }
            return ok(lines.isEmpty ? "No accounts configured." : lines.joined(separator: "\n"))

        case "list_labels":
            let ids = scope(args) ?? store.accounts().map(\.id)
            guard !ids.isEmpty else { return fail("No accounts configured.") }
            // Every account's labels, each line attributed — label ids are
            // per-account (Gmail mints its own), so a merged list that dropped
            // the account would hand back ids the caller cannot act on.
            let lines = ids.flatMap { accountID in
                store.labels(accountID: accountID).map { "\(accountID) · \($0.id) — \($0.name)" }
            }
            return ok(lines.isEmpty ? "No labels synced yet." : lines.joined(separator: "\n"))

        case "search_mail":
            let accountIDs = scope(args)
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

        case "unread_summary":
            let unread = UnifiedInbox.inbox(store: store, accountIDs: scope(args),
                                            months: recentMonths())
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
            // States the account: a reply has to go out from the mailbox that
            // received the thread, and the agent cannot know which that is
            // from the thread id alone.
            return ok("Subject: \(thread.subject)\nAccount: \(thread.accountID)\n\n"
                      + rendered.joined(separator: "\n---\n"))

        case "archive", "trash", "set_read", "star", "label":
            return await mutate(operation, args: args, store: store, outbox: outbox)

        case "create_draft":
            guard let to = (args["to"] as? [String])?.compactMap({ MailAddress(rfc5322: $0) }),
                  !to.isEmpty else { return fail("to required.") }
            // A draft must know which mailbox will send it: that decides the
            // signature and, at `send_draft`, the transmitting provider. A
            // reply within a thread takes the thread's account (there is only
            // one right answer); otherwise the caller states it, and it may
            // only be omitted while exactly one account is connected.
            let draftAccount: String?
            if let explicit = args["account_id"] as? String {
                guard store.accounts().contains(where: { $0.id == explicit }) else {
                    return fail("No account \(explicit). Call list_accounts for the ids.")
                }
                draftAccount = explicit
            } else if let threadID = args["thread_id"] as? String,
                      let thread = store.thread(threadID) {
                draftAccount = thread.accountID
            } else {
                let accounts = store.accounts()
                guard accounts.count <= 1 else {
                    return fail("Several accounts are connected, so account_id is required — " +
                                "a draft has to know which mailbox will send it. Call " +
                                "list_accounts for the ids.")
                }
                draftAccount = accounts.first?.id
            }
            let draft = OutgoingMessage(
                to: to,
                cc: (args["cc"] as? [String] ?? []).compactMap { MailAddress(rfc5322: $0) },
                subject: args["subject"] as? String ?? "",
                bodyText: args["body"] as? String ?? "",
                inReplyToMessageID: args["in_reply_to"] as? String,
                threadID: args["thread_id"] as? String,
                accountID: draftAccount)
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
            //
            // Undo-send hold: applied here too, for the SAME duration
            // (`SendAttempt.defaultHoldWindow`) as the human Send button.
            // Checked in `RavenMCPOperations` before deciding this — Sage's
            // send_draft passes through a human approval gate before this
            // tool ever runs, but that approval gate is not the same thing as
            // this window: it happens BEFORE the send is queued, not after,
            // and it is the user approving Sage's intent, not reviewing the
            // final rendered message about to leave the outbox. Giving Sage's
            // sends a shorter-or-absent hold would mean approving a Sage send
            // transmits FASTER than the user's own Compose Send button — the
            // opposite of the surprise a hold window exists to prevent — so
            // this deliberately uses the identical default rather than a
            // distinct "agent immediacy" contract. No evidence was found in
            // this file (prior to this change) of a deliberate immediacy
            // contract for send_draft to preserve instead.
            let result: SendAttempt.Result
            do {
                result = try await SendAttempt.send(
                    draft, draftID: id, outbox: outbox, store: store,
                    holdUntil: Date().addingTimeInterval(SendAttempt.defaultHoldWindow),
                    drain: outbox.drain)
            } catch {
                return fail("Could not queue send: \(error)")
            }
            // A still-queued send is reported without `isError`: nothing went
            // wrong, it simply hasn't gone out yet — including a send that is
            // merely held inside its undo-send window.
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
        //
        // The account comes from each THREAD, never from an `account_id`
        // argument or a default: a mutation must reach the mailbox the thread
        // actually lives in, and there is no honest way for the caller to
        // override that. Ids spanning two accounts therefore queue one entry
        // per account (`ThreadAccountGrouping`), shared with `RavenViewModel`
        // so the human and the agent resolve it identically.
        let groups = ThreadAccountGrouping.group(ids, store: store)
        ThreadMutationApplier.applyLocally(mutation, store: store)
        for group in groups {
            do {
                try outbox.enqueue(.labels(action.mutation(threadIDs: group.ids)),
                                   accountID: group.accountID)
            } catch {
                return fail("Applied locally but could not queue: \(error)")
            }
        }
        return ok("\(operation) applied to \(ids.count) thread(s) across " +
                  "\(groups.count) account(s); queued for sync.")
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
