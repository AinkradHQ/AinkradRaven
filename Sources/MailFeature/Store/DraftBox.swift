import Foundation

/// Drafts created by Sage must appear in Compose, and drafts typed in Compose
/// must be sendable by Sage — so both go through one in-memory box the app
/// owns. Deliberately not persisted in M0: an unsent draft dying with the app
/// is acceptable; a draft Sage cannot see is not.
///
/// Drafts are in-memory only, so ids are NOT stable across a process relaunch
/// — the box is empty again on the next launch. Ids are UUID strings rather
/// than a monotonic counter specifically so that an id from a previous
/// process lifetime can never collide with one from this lifetime: a counter
/// restarting at 1 after a relaunch would let a stale `send_draft("draft-1")`
/// call — left over in an agent conversation from before the restart — send
/// whatever unrelated draft happens to be first in the new process, which for
/// the one tool that actually transmits mail means the wrong recipient gets
/// the wrong email. Treat ids as opaque tokens: never parse or order them.
@MainActor public final class DraftBox {
    public static let shared = DraftBox()
    private var drafts: [String: OutgoingMessage] = [:]

    public func save(_ message: OutgoingMessage, id: String? = nil) throws -> String {
        let key = id ?? UUID().uuidString
        drafts[key] = message
        return key
    }

    public func draft(_ id: String) -> OutgoingMessage? { drafts[id] }
    public func all() -> [(id: String, message: OutgoingMessage)] {
        drafts.map { ($0.key, $0.value) }.sorted { $0.id < $1.id }
    }
    public func remove(_ id: String) { drafts.removeValue(forKey: id) }
}
