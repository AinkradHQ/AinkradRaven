import Foundation

/// Drafts created by Sage must appear in Compose, and drafts typed in Compose
/// must be sendable by Sage — so both go through one in-memory box the app
/// owns. Deliberately not persisted in M0: an unsent draft dying with the app
/// is acceptable; a draft Sage cannot see is not.
@MainActor public final class DraftBox {
    public static let shared = DraftBox()
    private var drafts: [String: OutgoingMessage] = [:]
    private var counter = 0

    public func save(_ message: OutgoingMessage, id: String? = nil) throws -> String {
        counter += 1
        let key = id ?? "draft-\(counter)"
        drafts[key] = message
        return key
    }

    public func draft(_ id: String) -> OutgoingMessage? { drafts[id] }
    public func all() -> [(id: String, message: OutgoingMessage)] {
        drafts.map { ($0.key, $0.value) }.sorted { $0.id < $1.id }
    }
    public func remove(_ id: String) { drafts.removeValue(forKey: id) }
}
