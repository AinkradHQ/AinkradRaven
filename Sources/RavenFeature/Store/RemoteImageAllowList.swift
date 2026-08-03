import Foundation
import AinkradAppKit

/// Persists which senders' remote images the user has explicitly chosen to
/// auto-load, so that choice survives closing and reopening the message (and
/// a fresh app launch) instead of resetting every time `RawHTMLSheet` is
/// opened — the gap called out in `ThreadSurface`'s original "Load images"
/// implementation.
///
/// Stored as a plain list of lowercased addresses in one document — this is
/// an allow-list of who the user trusts to show images, not a secret, so it
/// is fine to store plainly (per the task's own framing). The default for any
/// address NOT in this list is BLOCKED: an unknown sender's tracking pixel
/// must never fire just because the message was opened. That default is
/// enforced by `isAllowed` returning `false` on a decode failure or a missing
/// document, never by inverting the check.
public enum RemoteImageAllowList {
    private static func normalize(_ sender: String) -> String {
        sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether `sender` has previously been granted "Load images". Absent,
    /// empty, or corrupt storage all read as `false` — the blocked default.
    public static func isAllowed(_ sender: String, documents: PluginDocumentStore) -> Bool {
        allowed(documents: documents).contains(normalize(sender))
    }

    /// Persists that `sender`'s images should auto-load from now on.
    public static func allow(_ sender: String, documents: PluginDocumentStore) {
        var current = allowed(documents: documents)
        guard current.insert(normalize(sender)).inserted else { return }
        guard let data = try? JSONEncoder().encode(Array(current)) else { return }
        documents.setData(data, forKey: DocumentKeys.remoteImageAllowList)
    }

    private static func allowed(documents: PluginDocumentStore) -> Set<String> {
        guard let data = documents.data(forKey: DocumentKeys.remoteImageAllowList),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }
}
