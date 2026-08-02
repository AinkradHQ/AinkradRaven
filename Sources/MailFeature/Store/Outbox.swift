import Foundation
import AinkradAppKit

/// Mutations apply to the store immediately and land here for transmission, so
/// the UI is never blocked on the network. A failed entry retries; one that
/// exhausts its attempts is dead-lettered and surfaced, never silently dropped.
@MainActor public final class Outbox {
    private let documents: PluginDocumentStore
    private let provider: MailProvider
    private let maxAttempts: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var entries: [OutboxEntry] = []

    public init(documents: PluginDocumentStore, provider: MailProvider, maxAttempts: Int = 5) {
        self.documents = documents
        self.provider = provider
        self.maxAttempts = maxAttempts
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if let data = documents.data(forKey: DocumentKeys.outbox),
           let decoded = try? decoder.decode([OutboxEntry].self, from: data) {
            entries = decoded
        }
    }

    public func pending() -> [OutboxEntry] { entries.filter { !$0.isDeadLettered } }
    public func deadLettered() -> [OutboxEntry] { entries.filter(\.isDeadLettered) }

    public func enqueue(_ operation: OutboxEntry.Operation) throws {
        entries.append(OutboxEntry(operation: operation))
        try persist()
    }

    /// One pass over the queue. Called after a mutation and on the sync timer.
    public func drain() async {
        for entry in pending() {
            do {
                switch entry.operation {
                case .labels(let mutation):
                    try await provider.applyLabels(mutation)
                case .send(let message):
                    _ = try await provider.send(message)
                }
                entries.removeAll { $0.id == entry.id }
            } catch {
                guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                entries[index].attempts += 1
                entries[index].lastError = String(describing: error)
                if entries[index].attempts >= maxAttempts {
                    entries[index].isDeadLettered = true
                }
            }
        }
        try? persist()
    }

    /// Exponential backoff in seconds for an entry's next attempt. The caller
    /// (the sync timer) decides when to drain; this states how long to wait.
    public static func backoff(forAttempt attempt: Int) -> TimeInterval {
        min(300, pow(2, Double(max(0, attempt))))
    }

    public func discard(_ id: UUID) throws {
        entries.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        documents.setData(try encoder.encode(entries), forKey: DocumentKeys.outbox)
    }
}
