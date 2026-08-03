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
    @discardableResult
    func enqueue(_ operation: OutboxEntry.Operation) throws -> UUID
}

@MainActor public final class Outbox: MutationOutbox {
    private let documents: PluginDocumentStore
    private let provider: MailProvider
    private let maxAttempts: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var entries: [OutboxEntry] = []
    /// True for exactly as long as a `drain()` pass is running, including
    /// while it is suspended on the network. See `drain()` for why this is
    /// load-bearing rather than tidiness.
    private var isDraining = false

    /// The account whose provider this outbox currently transmits through.
    /// Set by `RavenRuntime` whenever a provider is attached. Entries are
    /// stamped with it at `enqueue`, and an entry stamped with a *different*
    /// account is never drained — see `OutboxEntry.accountID`.
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

    public init(documents: PluginDocumentStore, provider: MailProvider,
                maxAttempts: Int = 5, accountID: String? = nil) {
        self.documents = documents
        self.provider = provider
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
        entries.filter {
            !$0.isDeadLettered && !$0.needsReview && $0.inFlightAt == nil
                && ($0.accountID == nil || $0.accountID == accountID)
        }
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
    public func needsReview() -> [OutboxEntry] { entries.filter(\.needsReview) }

    /// Returns the id of the entry just queued, so a caller that must know
    /// this exact operation's fate (`SendAttempt`) can ask for it by id rather
    /// than diffing `pending()` — a diff cannot see an entry that a concurrent
    /// drain has already taken in-flight.
    @discardableResult
    public func enqueue(_ operation: OutboxEntry.Operation) throws -> UUID {
        let entry = OutboxEntry(operation: operation, accountID: accountID)
        entries.append(entry)
        persistRecordingFailure()
        return entry.id
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
        defer { isDraining = false }
        for entry in pending() {
            markInFlight(entry.id)
            do {
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
}
