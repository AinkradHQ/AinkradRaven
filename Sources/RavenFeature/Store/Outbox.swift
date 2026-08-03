import Foundation
import AinkradAppKit

/// Mutations apply to the store immediately and land here for transmission, so
/// the UI is never blocked on the network. A failed entry retries; one that
/// exhausts its attempts is dead-lettered and surfaced, never silently dropped.
///
/// This is at-most-once delivery, not exactly-once — genuinely exactly-once
/// would need a provider-side idempotency key, which the Gmail send API does
/// not offer. Instead of faking it, every operation is persisted as "in flight"
/// immediately before it is handed to the provider. If the process dies between
/// the network call returning and the success being recorded, the entry is
/// found still marked in-flight on the next launch. Rather than guess whether
/// the call actually succeeded and risk resending — which for a `.send` means
/// the recipient gets the same email twice — that entry is pulled out of
/// `pending()` entirely and surfaced via `needsReview()` for a human to
/// resolve. This trades a possible missed send (rare: only the crash window
/// between transmission and the next persist) for never silently duplicating
/// one. For email, a missed send is recoverable (the user notices and resends);
/// a duplicate send is not (it already reached the recipient) — so the trade
/// is made in favor of "may need manual confirmation" over "sent twice".
/// The one method `RavenViewModel` actually needs from `Outbox` — pulled out
/// into a protocol so a test can inject a fake that fails `enqueue`, without
/// a real `Outbox` (which only ever fails to persist on an encoding error,
/// not something a test can trigger through its public API) standing in the
/// way of exercising that path.
@MainActor public protocol MutationOutbox: AnyObject {
    /// `accountID` is the account the operation belongs to — the thread's
    /// account for a mutation, the composing account for a send. `nil` falls
    /// back to the outbox's own default stamp, which is only unambiguous while
    /// a single account is connected.
    @discardableResult
    func enqueue(_ operation: OutboxEntry.Operation, accountID: String?) throws -> UUID
}

extension MutationOutbox {
    @discardableResult
    public func enqueue(_ operation: OutboxEntry.Operation) throws -> UUID {
        try enqueue(operation, accountID: nil)
    }
}

@MainActor public final class Outbox: MutationOutbox {
    private let documents: PluginDocumentStore
    /// Which provider transmits which account's entries. Every entry is routed
    /// through this by its OWN `accountID` (see `provider(forEntryAccount:)`),
    /// so a send composed on account A goes out through A's provider no matter
    /// what else is attached.
    private let router: MailProviderRouter
    private let maxAttempts: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var entries: [OutboxEntry] = []
    /// True for exactly as long as a `drain()` pass is running, including
    /// while it is suspended on the network. See `drain()` for why this is
    /// load-bearing rather than tidiness.
    private var isDraining = false

    /// The default account stamp for an `enqueue` that names none, and — in
    /// the single-provider mode below — the account this outbox claims to
    /// transmit for. An entry stamped with a *different* account is never
    /// drained in that mode; see `provider(forEntryAccount:)`.
    public var accountID: String?

    /// Ids `drain()` saw returned successfully from the provider. This is the
    /// ONLY evidence `outcome(for:)` accepts as success — see its
    /// documentation. In-memory and per-process by design: a caller only ever
    /// asks about an id it was just handed by `enqueue`, and a process that
    /// died mid-send is already handled by the `needsReview` conversion in
    /// `init`, which must not be second-guessed by a persisted "it was sent"
    /// claim we could not actually verify.
    private var transmitted: Set<UUID> = []
    /// Insertion order for `transmitted`, so it can be trimmed. Without a cap
    /// this set would grow for the life of the process; outcomes are only ever
    /// queried immediately after the drain that produced them, so a small
    /// window is ample.
    private var transmittedOrder: [UUID] = []
    private static let transmittedMemory = 256

    /// Set whenever the most recent attempt to persist the queue failed. Never
    /// swallowed silently — callers (and tests) can inspect this to know the
    /// on-disk queue may be stale relative to memory.
    public private(set) var lastPersistenceError: String?

    /// The single outstanding one-shot wake, if any — see `scheduleWake()`.
    /// Exactly one at a time; scheduling a new one always cancels whatever
    /// was here first. `DispatchWorkItem` + `DispatchQueue.main.asyncAfter`
    /// on purpose, matching `GmailAuth.Coordinator`'s OAuth-listener-timeout
    /// discipline (see that type's `timeoutWorkItem`): a stored, cancellable
    /// work item on the main queue, not an unstructured `Task` (which would
    /// run on the concurrent executor) and not a second polling loop.
    private var wakeWorkItem: DispatchWorkItem?
    /// Invoked when the one-shot wake fires, instead of calling `drain()`
    /// directly. `RavenRuntime` sets this to its own `drainOutbox()` so the
    /// dead-letter/needs-review snapshots the Accounts surface renders are
    /// refreshed too — `Outbox` itself has no knowledge of `RavenRuntime`, so
    /// it cannot do that refresh on its own. `nil` (the default, and every
    /// existing test) falls back to calling `drain()` alone.
    public var onWake: (() async -> Void)?

    /// Single-provider form, kept for the one-account/test case: every entry
    /// this outbox is willing to drain goes through `provider`, and an entry
    /// stamped for an account other than `accountID` is refused (see
    /// `provider(forEntryAccount:)`).
    public convenience init(documents: PluginDocumentStore, provider: MailProvider,
                            maxAttempts: Int = 5, accountID: String? = nil) {
        self.init(documents: documents, router: MailProviderRouter(single: provider),
                  maxAttempts: maxAttempts, accountID: accountID)
    }

    public init(documents: PluginDocumentStore, router: MailProviderRouter,
                maxAttempts: Int = 5, accountID: String? = nil) {
        self.documents = documents
        self.router = router
        self.maxAttempts = maxAttempts
        self.accountID = accountID
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if let data = documents.data(forKey: DocumentKeys.outbox),
           let decoded = try? decoder.decode([OutboxEntry].self, from: data) {
            entries = decoded.map { entry in
                var entry = entry
                if entry.inFlightAt != nil && !entry.isDeadLettered && !entry.needsReview {
                    entry.needsReview = true
                    if entry.lastError == nil {
                        entry.lastError = "A previous process exited while this operation was " +
                            "in flight; whether it reached the provider is unknown. Held for " +
                            "manual review rather than resent, to avoid a possible duplicate."
                    }
                }
                return entry
            }
        }
        // Re-derive the wake from whatever was just loaded, so a hold or
        // scheduled send that came due while the app was closed does not
        // have to wait for the first sync-timer tick (which, in the real
        // runtime, already runs immediately on launch) or, for an `Outbox`
        // used standalone (a test, or an MCP-only host), for a wake that
        // otherwise would never be scheduled at all.
        scheduleWake()
    }

    /// Entries eligible for the next `drain()` pass.
    ///
    /// `inFlightAt != nil` is excluded here for a different reason than
    /// `needsReview`: `needsReview` covers the *crash* case (a previous
    /// process died mid-operation — `init` converts those on load), whereas
    /// this filter covers the *concurrent* case (a drain in this same process
    /// is suspended on the network with this entry already handed to the
    /// provider). Without it, a second drain overlapping the first would see
    /// the entry still eligible, mark it in-flight again, and send the same
    /// email twice. Both filters are needed; neither subsumes the other.
    public func pending() -> [OutboxEntry] {
        reviewUnattributableLegacyEntries()
        return entries.filter {
            !$0.isDeadLettered && !$0.needsReview && $0.inFlightAt == nil
                && $0.isEligible() && provider(forEntryAccount: $0.accountID) != nil
        }
    }

    /// An entry with no `accountID` at all — queued before per-account
    /// routing existed, or by the single-provider convenience init/tests —
    /// is not itself a problem: `provider(forEntryAccount:)`'s own fallback
    /// resolves it to the claimed or sole account, exactly as intended for
    /// that ordinary case, and such an entry is left alone here. The gap this
    /// closes is narrower: a nil-stamped entry that fallback CANNOT resolve
    /// — several real accounts routed and none claimed as the default — has
    /// no account to fall back to and, left alone, would sit in `pending()`
    /// forever without ever being drained OR being visible anywhere. Rather
    /// than strand it silently, it is pulled into `needsReview()` so a human
    /// sees it and can re-attribute (discard, or re-`enqueue` with an
    /// explicit account) it. Re-checked on every `pending()`/`needsReview()`
    /// read rather than once at load, since which accounts are attached can
    /// change after the outbox itself is constructed (see `RavenRuntime.
    /// init`, which attaches providers after the outbox already exists).
    private func reviewUnattributableLegacyEntries() {
        var changed = false
        for index in entries.indices {
            let entry = entries[index]
            guard entry.accountID == nil, !entry.isDeadLettered, !entry.needsReview,
                  entry.inFlightAt == nil, provider(forEntryAccount: nil) == nil
            else { continue }
            entries[index].needsReview = true
            if entries[index].lastError == nil {
                entries[index].lastError = "This operation has no attributed account, and no " +
                    "connected account is an unambiguous default. Held for manual review rather " +
                    "than guessed at, since guessing wrong would send or apply it against the " +
                    "wrong mailbox."
            }
            changed = true
        }
        if changed { persistRecordingFailure() }
    }

    /// The provider that may transmit an entry stamped `entryAccountID`, or
    /// `nil` if none may — which is what keeps the entry out of `pending()`.
    ///
    /// This is where "the entry's own account is authoritative" is implemented.
    /// In the routed (real runtime) case the entry's account is looked up
    /// directly, so several accounts drain side by side and each goes out
    /// through its own provider. The `acceptsAnyAccount` case is the
    /// single-provider convenience init: there the outbox *claims* one account,
    /// and an entry stamped for a different one is refused outright rather than
    /// transmitted from the wrong mailbox — the M0 backstop, preserved
    /// verbatim, since a lone provider cannot tell the difference itself.
    /// A `nil` stamp ("queued before any account was known") routes to the
    /// claimed account if there is one, else to the sole provider if there is
    /// exactly one, else nowhere — guessing between two mailboxes would be
    /// worse than leaving it queued.
    private func provider(forEntryAccount entryAccountID: String?) -> MailProvider? {
        guard let entryAccountID else {
            if let accountID, let claimed = router.provider(for: accountID) { return claimed }
            return router.sole
        }
        if router.acceptsAnyAccount, let accountID, accountID != entryAccountID { return nil }
        return router.provider(for: entryAccountID)
    }

    /// Entries handed to the provider by a drain that has not yet come back.
    /// Not pending (they must not be resent) and not an outcome — a caller
    /// asking "did my send go out?" must treat this as "not yet".
    public func inFlight() -> [OutboxEntry] {
        entries.filter { $0.inFlightAt != nil && !$0.isDeadLettered && !$0.needsReview }
    }
    public func deadLettered() -> [OutboxEntry] { entries.filter(\.isDeadLettered) }
    /// Entries whose outcome is unknown because a previous process died while
    /// they were in flight. Excluded from `pending()` so they are never
    /// silently retried; a human must resolve them (confirm the send did or
    /// didn't happen, then `discard` or re-`enqueue` as appropriate).
    public func needsReview() -> [OutboxEntry] {
        reviewUnattributableLegacyEntries()
        return entries.filter(\.needsReview)
    }

    /// Returns the id of the entry just queued, so a caller that must know
    /// this exact operation's fate (`SendAttempt`) can ask for it by id rather
    /// than diffing `pending()` — a diff cannot see an entry that a concurrent
    /// drain has already taken in-flight.
    /// The stamp precedence is deliberate: a `.send`'s own
    /// `OutgoingMessage.accountID` wins, then an explicitly passed
    /// `accountID` (the thread's account, for a mutation), then this outbox's
    /// default. A send therefore cannot be re-attributed to a different
    /// mailbox by whatever happens to be attached when it is queued.
    @discardableResult
    public func enqueue(_ operation: OutboxEntry.Operation,
                        accountID explicit: String? = nil) throws -> UUID {
        try enqueue(operation, accountID: explicit, holdUntil: nil, sendAt: nil, draftID: nil)
    }

    /// The undo-send/scheduled-send form. Kept as a SEPARATE overload from
    /// the plain `enqueue(_:accountID:)` above (rather than adding defaulted
    /// parameters to it) because that plain form is `MutationOutbox`'s
    /// protocol requirement — widening its own parameter list would stop it
    /// satisfying the protocol. `holdUntil`/`sendAt` are gated identically by
    /// `OutboxEntry.isEligible`; `draftID` is threaded onto the entry so
    /// `drain()` can clean up the right draft whenever this entry eventually
    /// transmits, however long after this call returns.
    @discardableResult
    public func enqueue(_ operation: OutboxEntry.Operation, accountID explicit: String?,
                        holdUntil: Date?, sendAt: Date?, draftID: String?) throws -> UUID {
        var stamp = explicit ?? accountID
        if case .send(let message) = operation, let composed = message.accountID {
            stamp = composed
        }
        let entry = OutboxEntry(operation: operation, accountID: stamp,
                                holdUntil: holdUntil, sendAt: sendAt, draftID: draftID)
        entries.append(entry)
        persistRecordingFailure()
        scheduleWake()
        return entry.id
    }

    /// Cancels a still-held `.send` entry (undo-send) and hands back the
    /// message it was queuing, so the caller can restore it as an editable
    /// draft. Returns `nil` — leaving the queue untouched — for anything that
    /// is NOT provably still held: an unknown id, a `.labels` entry, one
    /// already handed to a provider (`inFlightAt != nil`), or one whose hold
    /// has already elapsed. Deliberately narrower than `discard`, which drops
    /// any entry unconditionally: this may only ever remove something that
    /// has not yet been (and, by the elapsed-hold check, is not about to be)
    /// transmitted, so "cancel" can never race a real send.
    public func cancelHeld(_ id: UUID) -> OutgoingMessage? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries[index]
        guard entry.inFlightAt == nil, case .send(let message) = entry.operation else { return nil }
        guard let holdUntil = entry.holdUntil, Date() < holdUntil else { return nil }
        entries.remove(at: index)
        persistRecordingFailure()
        scheduleWake()
        return message
    }

    /// What actually became of one queued operation.
    ///
    /// `.sent` is returned ONLY for an id `drain()` recorded as genuinely
    /// transmitted. Absence from the queue is deliberately NOT treated as
    /// success: `purge(accountID:)` and `discard(_:)` also remove entries, so
    /// "not found" would otherwise mean a sign-out (or a discard) racing a
    /// suspended `drain()` reports `.sent` for a message that never left the
    /// machine — the user is told "Sent" and their draft is deleted. That is
    /// precisely the false-success class this whole outcome type exists to
    /// eliminate, so success must be RECORDED, never inferred.
    public func outcome(for id: UUID) -> OutboxSendOutcome {
        if transmitted.contains(id) { return .sent }
        guard let entry = entries.first(where: { $0.id == id })
        else { return .removedWithoutSending }
        if entry.isDeadLettered { return .deadLettered(lastError: entry.lastError) }
        if entry.needsReview { return .needsReview }
        return .queued(inFlight: entry.inFlightAt != nil)
    }

    /// Drops every entry belonging to `accountID`. Called on sign-out: a
    /// queued operation for an account that is no longer connected must never
    /// be transmitted through whatever account connects next.
    public func purge(accountID: String) {
        entries.removeAll { $0.accountID == accountID }
        persistRecordingFailure()
        scheduleWake()
    }

    /// One pass over the queue. Called after a mutation and on the sync timer.
    /// Persists after every entry is resolved (marked in-flight, removed on
    /// success, or updated with a new attempt count / dead-letter flag on
    /// failure) rather than once at the end of the pass — that narrows the
    /// window in which an unpersisted crash could cause a resend from "the
    /// whole drain" down to "one operation".
    ///
    /// NON-REENTRANT, and that is a correctness requirement, not an
    /// optimization. This method is `@MainActor`, but it *suspends* at
    /// `await provider.send` — which frees the main actor. The sync timer's
    /// `syncOnce()`, an MCP `send_draft` call, and the Settings retry button
    /// can all call `drain()` during that window. A second pass entering here
    /// would re-send an operation the first pass has already handed to the
    /// provider (the recipient gets the email twice) and could remove an entry
    /// out from under the first pass, making a failed send read as "Sent".
    /// The guard makes the second call a no-op; its work is not lost, because
    /// the entries it would have processed are still queued for the next pass.
    public func drain() async {
        guard !isDraining else { return }
        isDraining = true
        // Recomputed unconditionally on the way out — whether every entry
        // transmitted, failed and backed off, or nothing was eligible at
        // all — since any of those can change which entry (if any) is now
        // the earliest still waiting on a future `holdUntil`/`sendAt`.
        defer { isDraining = false; scheduleWake() }
        for entry in pending() {
            // Resolved per entry, never once per pass: two accounts' entries
            // can sit in the same queue and each must leave through its own
            // provider. `pending()` already excluded anything unroutable, so
            // this lookup is a repeat of that decision, not a new one.
            guard let provider = provider(forEntryAccount: entry.accountID) else { continue }
            markInFlight(entry.id)
            do {
                // Enforced again here, at the point of actual transmission,
                // even though `MailProviderRouter.writableProvider` is the
                // canonical chokepoint: `provider(forEntryAccount:)` resolves
                // through `router.sole`/`acceptsAnyAccount` fallbacks that
                // `writableProvider(for:)` (keyed on one exact account id)
                // cannot express, so the capability check has to happen on
                // whichever provider this lookup actually returned.
                guard provider.capabilities == .readWrite else {
                    throw MailError.readOnlyAccount(provider.accountID)
                }
                switch entry.operation {
                case .labels(let mutation):
                    try await provider.applyLabels(mutation)
                case .send(let message):
                    _ = try await provider.send(message)
                }
                // Record the success BEFORE removing the entry. From here on
                // this id is the only kind of "gone" that means sent; every
                // other removal (purge, discard) leaves no such record.
                recordTransmitted(entry.id)
                entries.removeAll { $0.id == entry.id }
                persistRecordingFailure()
                // A held or scheduled send's draft could not be cleaned up
                // when it was queued — `SendAttempt.send` had already
                // returned by the time this drain (the 120s timer, most
                // likely) actually transmits it. The draft id travels on the
                // entry itself for exactly this: whichever drain pass finally
                // sends it removes the draft, same "removed iff sent"
                // invariant, just applied here instead of only at enqueue time.
                if let draftID = entry.draftID {
                    DraftBox.shared.remove(draftID)
                }
            } catch {
                guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                entries[index].inFlightAt = nil
                entries[index].attempts += 1
                entries[index].lastError = String(describing: error)
                if entries[index].attempts >= maxAttempts {
                    entries[index].isDeadLettered = true
                }
                persistRecordingFailure()
            }
        }
    }

    /// Exponential backoff in seconds for an entry's next attempt. The caller
    /// (the sync timer) decides when to drain; this states how long to wait.
    public static func backoff(forAttempt attempt: Int) -> TimeInterval {
        min(300, pow(2, Double(max(0, attempt))))
    }

    public func discard(_ id: UUID) throws {
        entries.removeAll { $0.id == id }
        persistRecordingFailure()
        scheduleWake()
    }

    /// Marks the entry as in-flight and persists that immediately, before the
    /// provider call is made. This is the write that lets a future launch
    /// recognize "this operation's outcome is unknown" instead of blindly
    /// resending it.
    private func recordTransmitted(_ id: UUID) {
        guard transmitted.insert(id).inserted else { return }
        transmittedOrder.append(id)
        while transmittedOrder.count > Self.transmittedMemory {
            transmitted.remove(transmittedOrder.removeFirst())
        }
    }

    private func markInFlight(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].inFlightAt = Date()
        persistRecordingFailure()
    }

    private func persistRecordingFailure() {
        do {
            try persist()
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = String(describing: error)
        }
    }

    private func persist() throws {
        documents.setData(try encoder.encode(entries), forKey: DocumentKeys.outbox)
    }

    // MARK: One-shot wake (undo-send/scheduled-send skew fix)

    /// The soonest time at which SOME pending-shaped entry becomes eligible,
    /// or `nil` if none carries a `holdUntil`/`sendAt` gate at all. Mirrors
    /// `pending()`'s own filter (dead-lettered, needing review, in-flight,
    /// and unroutable entries are excluded identically) so this never
    /// schedules a wake for an entry `drain()` would refuse to touch anyway.
    ///
    /// Deliberately NOT restricted to a date still in the future: an entry
    /// whose gate already elapsed — most notably one restored from disk on
    /// launch after sitting held/scheduled while the app was closed — must
    /// still produce a due date here, so `scheduleWake()` below fires for it
    /// essentially immediately instead of silently waiting for the next
    /// mutation or the 120s backstop tick.
    ///
    /// `due` for an entry is the LATER of its `holdUntil`/`sendAt` — matching
    /// `OutboxEntry.isEligible`, which requires BOTH (when set) to have
    /// passed, not either.
    private func earliestDueDate() -> Date? {
        entries.compactMap { entry -> Date? in
            guard !entry.isDeadLettered, !entry.needsReview, entry.inFlightAt == nil,
                  provider(forEntryAccount: entry.accountID) != nil else { return nil }
            return [entry.holdUntil, entry.sendAt].compactMap { $0 }.max()
        }.min()
    }

    /// Replaces whatever wake was scheduled with one for the new earliest
    /// due time — ONE outstanding `DispatchWorkItem` at a time, never one
    /// per entry. Called after every mutation that could change which entry
    /// is soonest (`enqueue`, `cancelHeld`, `discard`, `purge`, the end of
    /// every `drain()` pass) and once from `init` so a relaunch re-derives
    /// it from whatever was just loaded, rather than waiting for the next
    /// mutation to schedule the first one.
    private func scheduleWake() {
        wakeWorkItem?.cancel()
        wakeWorkItem = nil
        guard let due = earliestDueDate() else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let onWake = self.onWake {
                    await onWake()
                } else {
                    await self.drain()
                }
            }
        }
        wakeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow),
                                      execute: workItem)
    }

    /// Cancels the pending wake, same discipline as `RavenRuntime.teardown()`
    /// cancelling the sync timer's `Task`. Called from `RavenRuntime.
    /// teardown()` — a torn-down runtime must never fire a wake into a
    /// provider it has already released. Safe to call more than once.
    public func teardownWake() {
        wakeWorkItem?.cancel()
        wakeWorkItem = nil
    }
}
