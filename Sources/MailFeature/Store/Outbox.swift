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
@MainActor public final class Outbox {
    private let documents: PluginDocumentStore
    private let provider: MailProvider
    private let maxAttempts: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var entries: [OutboxEntry] = []

    /// Set whenever the most recent attempt to persist the queue failed. Never
    /// swallowed silently — callers (and tests) can inspect this to know the
    /// on-disk queue may be stale relative to memory.
    public private(set) var lastPersistenceError: String?

    public init(documents: PluginDocumentStore, provider: MailProvider, maxAttempts: Int = 5) {
        self.documents = documents
        self.provider = provider
        self.maxAttempts = maxAttempts
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

    public func pending() -> [OutboxEntry] {
        entries.filter { !$0.isDeadLettered && !$0.needsReview }
    }
    public func deadLettered() -> [OutboxEntry] { entries.filter(\.isDeadLettered) }
    /// Entries whose outcome is unknown because a previous process died while
    /// they were in flight. Excluded from `pending()` so they are never
    /// silently retried; a human must resolve them (confirm the send did or
    /// didn't happen, then `discard` or re-`enqueue` as appropriate).
    public func needsReview() -> [OutboxEntry] { entries.filter(\.needsReview) }

    public func enqueue(_ operation: OutboxEntry.Operation) throws {
        entries.append(OutboxEntry(operation: operation))
        persistRecordingFailure()
    }

    /// One pass over the queue. Called after a mutation and on the sync timer.
    /// Persists after every entry is resolved (marked in-flight, removed on
    /// success, or updated with a new attempt count / dead-letter flag on
    /// failure) rather than once at the end of the pass — that narrows the
    /// window in which an unpersisted crash could cause a resend from "the
    /// whole drain" down to "one operation".
    public func drain() async {
        for entry in pending() {
            markInFlight(entry.id)
            do {
                switch entry.operation {
                case .labels(let mutation):
                    try await provider.applyLabels(mutation)
                case .send(let message):
                    _ = try await provider.send(message)
                }
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
