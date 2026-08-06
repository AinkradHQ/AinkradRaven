import Foundation
import AinkradAppKit

/// Every WRITE tool body, plus the shared argument decoding and result shapes.
/// Takes a store and an outbox — deliberately no provider, so a tool
/// physically cannot reach the network ahead of the store.
///
/// The read tools live in `RavenMCPReadOperations`, which takes no outbox at
/// all; see that file for why the split falls there.
public enum RavenMCPOperations {
    private static func decode(_ arguments: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
    }

    /// Internal rather than private so `RavenMCPReadOperations` produces
    /// byte-identical result shapes: two copies of `AgentActionResult(text:
    /// isError:)` is exactly how a read tool ends up reporting an error as a
    /// success.
    static func ok(_ text: String) -> AgentActionResult {
        AgentActionResult(text: text, isError: false)
    }

    static func fail(_ text: String) -> AgentActionResult {
        AgentActionResult(text: text, isError: true)
    }

    /// The accounts a read covers: the one named by `account_id`, or EVERY
    /// account when it is omitted.
    ///
    /// Omitting `account_id` used to fall back to `store.accounts().first`,
    /// which meant "what's unread?" answered for an arbitrary mailbox and
    /// quietly ignored the rest. `nil` here means all accounts, which is what
    /// the caller actually asked for; `UnifiedInbox` does the merge so the
    /// answer matches the Inbox exactly.
    static func scope(_ args: [String: Any]) -> [String]? {
        (args["account_id"] as? String).map { [$0] }
    }

    /// The most bundles `bundle_by_sender` will return, and the cap an
    /// oversized `limit` is clamped to. A tool response is text a model reads,
    /// so an unbounded `limit` is a way to spend a context window rather than a
    /// feature; 200 is well past any triage session and far short of a problem.
    static let maxLimit = 200

    /// `limit` validated at the boundary: absent means the default, a
    /// non-positive or non-integer value is REFUSED rather than silently
    /// coerced (asking for 0 or -1 senders is a caller bug, and answering it
    /// with 25 hides that), and an oversized one is clamped to `maxLimit`.
    /// `nil` means "reject the call".
    ///
    /// Internal rather than private so a test can observe the CLAMP directly:
    /// through the tool it is invisible unless a fixture holds more than
    /// `maxLimit` senders, and an assertion that only checks the oversized call
    /// succeeds would pass just as well with no clamp at all.
    static func boundedLimit(_ args: [String: Any], default fallback: Int = 25) -> Int? {
        guard let raw = args["limit"] else { return fallback }
        guard let value = raw as? Int, value > 0 else { return nil }
        return min(value, maxLimit)
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

        // The read half first. It answers `nil` for anything that is not one of
        // its tools, so there is still exactly one place an unknown operation
        // is reported.
        if let read = await RavenMCPReadOperations.run(operation, args: args, store: store,
                                                      providers: providers) {
            return read
        }

        switch operation {
        case "archive", "trash", "set_read", "star", "label":
            return await mutate(operation, args: args, store: store, outbox: outbox, providers: providers)

        case "label_with_reason":
            return await labelWithReason(args: args, store: store, outbox: outbox,
                                         providers: providers)

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
            // Refused up front, before anything is saved: a draft composed
            // against a read-only account (Apple Mail import) can never be
            // sent, so telling the caller now — rather than letting
            // `send_draft` discover it later — avoids a draft that silently
            // cannot go anywhere.
            if let draftAccount, let providers,
               providers.provider(for: draftAccount)?.capabilities == .readOnly {
                return fail("Account \(draftAccount) is read-only (imported mail) and cannot send.")
            }
            let draft = OutgoingMessage(
                to: to,
                cc: (args["cc"] as? [String] ?? []).compactMap { MailAddress(rfc5322: $0) },
                bcc: (args["bcc"] as? [String] ?? []).compactMap { MailAddress(rfc5322: $0) },
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
            if let accountID = draft.accountID, let providers,
               providers.provider(for: accountID)?.capabilities == .readOnly {
                return fail("Account \(accountID) is read-only (imported mail) and cannot send.")
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

    /// `label`, plus a locally recorded why.
    ///
    /// Deliberately NOT a second mutation path: everything after the two
    /// validations delegates to `mutate("label", …)`, so the rendered
    /// `LabelMutation`, the local application and the queued outbox entry are
    /// produced by the same code the plain `label` tool and the human UI use.
    /// A divergence here would be invisible in the tool's own response and
    /// visible only in the mailbox, which is why
    /// `RavenMCPLabelWithReasonTests` asserts the two tools' queued mutations
    /// are equal rather than asserting this one's shape.
    ///
    /// The reason is recorded AFTER the store write and the enqueue, and before
    /// returning. That order matters in one direction only: the mutation is the
    /// user-visible effect and must not wait on a log write, while a reason
    /// recorded for a mutation that was refused would be a lie about what
    /// happened.
    @MainActor
    private static func labelWithReason(args: [String: Any], store: MailStore, outbox: Outbox,
                                        providers: MailProviderRouter?) async -> AgentActionResult {
        // Validated at the boundary, before any thread is touched: an
        // over-long or blank reason is a caller bug, and applying the label
        // anyway would leave a labelled thread with no auditable why — the
        // whole point of this tool over `label`.
        guard let rawReason = args["reason"] as? String else {
            return fail("reason required — use the plain label tool if there is nothing to record.")
        }
        guard let reason = LabelReason.validated(rawReason) else {
            return fail("reason must be non-blank and at most " +
                        "\(LabelReason.maxReasonLength) characters; nothing was applied.")
        }
        guard let ids = args["thread_ids"] as? [String], !ids.isEmpty else {
            return fail("thread_ids required.")
        }
        // Every id is resolved BEFORE the first write. `mutate` alone would
        // file an unknown id under the `nil` account and still apply the label
        // to the ids it did know, which for a reasoned label is a partial
        // application the caller was told nothing about.
        let unknown = ids.filter { store.thread($0) == nil }
        guard unknown.isEmpty else {
            return fail("No thread(s) \(unknown.sorted().joined(separator: ", ")) in the store; " +
                        "nothing was applied and no reason was recorded.")
        }
        let add = args["add"] as? [String] ?? []
        let remove = args["remove"] as? [String] ?? []
        let applied = await mutate("label", args: ["thread_ids": ids, "add": add, "remove": remove],
                                   store: store, outbox: outbox, providers: providers)
        guard !applied.isError else { return applied }

        let recordedAt = Date()
        for id in ids {
            guard let accountID = store.thread(id)?.accountID else { continue }
            do {
                try store.recordLabelReason(
                    LabelReason(threadID: id, add: add, remove: remove,
                                reason: reason, recordedAt: recordedAt),
                    accountID: accountID)
            } catch {
                // The label IS applied and queued; saying otherwise would be
                // the worse lie. Reported as an error so the caller knows the
                // audit trail it asked for does not exist.
                return fail("label applied and queued, but the reason could not be " +
                            "recorded: \(error)")
            }
        }
        return ok(applied.text + "\nReason recorded locally for \(ids.count) thread(s); it is " +
                  "never attached to a provider mutation and never leaves this machine.")
    }

    @MainActor
    private static func mutate(_ operation: String, args: [String: Any],
                               store: MailStore, outbox: Outbox,
                               providers: MailProviderRouter? = nil) async -> AgentActionResult {
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
        // Read-only accounts are excluded BEFORE anything is applied locally:
        // applying a mutation to the store for a thread that can never sync
        // (Apple Mail import has no transport to carry it) would leave the
        // store permanently disagreeing with the account it imported from.
        let readOnlyAccountIDs = Set(groups.compactMap(\.accountID).filter {
            providers?.provider(for: $0)?.capabilities == .readOnly
        })
        let writableGroups = groups.filter { group in
            group.accountID.map { !readOnlyAccountIDs.contains($0) } ?? true
        }
        guard !writableGroups.isEmpty else {
            return fail("Account(s) \(readOnlyAccountIDs.sorted().joined(separator: ", ")) " +
                        "are read-only (imported mail); \(operation) cannot be applied.")
        }
        let writableIDs = Set(writableGroups.flatMap(\.ids))
        // Resolved and rendered per account, for the same reason `RavenViewModel`
        // does it: the rendered strings belong to one backend. An unresolvable
        // backend is refused here too, so the agent path and the human path
        // cannot disagree about what is mutable.
        var unsupported: [String] = []
        for group in writableGroups {
            guard let vocabulary = LabelVocabularyResolver.vocabulary(forAccountID: group.accountID,
                                                                     store: store) else {
                unsupported.append(group.accountID ?? "unknown")
                continue
            }
            let mutation = action.labelMutation(threadIDs: group.ids, vocabulary: vocabulary)
            ThreadMutationApplier.applyLocally(mutation, store: store, vocabulary: vocabulary)
            do {
                try outbox.enqueue(.labels(mutation), accountID: group.accountID)
            } catch {
                return fail("Applied locally but could not queue: \(error)")
            }
        }
        guard unsupported.count < writableGroups.count else {
            return fail("Account(s) \(unsupported.sorted().joined(separator: ", ")) use a backend " +
                        "this build cannot apply \(operation) to.")
        }
        let skipped = readOnlyAccountIDs.isEmpty ? "" :
            " (skipped read-only account(s) \(readOnlyAccountIDs.sorted().joined(separator: ", ")))"
        return ok("\(operation) applied to \(writableIDs.count) thread(s) across " +
                  "\(writableGroups.count) account(s); queued for sync.\(skipped)")
    }
}
