import Foundation

/// Every `PluginDocumentStore` key the app writes, in one place, so a rename
/// is one edit and a migration can enumerate them.
public enum DocumentKeys {
    public static let accounts = "accounts"
    public static let outbox = "outbox"
    /// Per-sender "Load images" opt-in — see `RemoteImageAllowList`. Not
    /// scoped per-account: the same sender address means the same person
    /// regardless of which of the user's own accounts received the mail.
    public static let remoteImageAllowList = "remote-image-allow-list"
    public static func index(accountID: String, month: String) -> String {
        "index-\(accountID)-\(month)"
    }
    /// The set of month shards an account has ever written. The host's
    /// document store cannot enumerate keys, so without this a sign-out purge
    /// has no way to find the threads it must delete.
    public static func indexMonths(accountID: String) -> String {
        "index-months-\(accountID)"
    }
    /// Every message id an account has stored a body for. Bodies are keyed by
    /// message id alone, so without this a sign-out purge can only find the
    /// ones still reachable through a thread document.
    public static func bodyIndex(accountID: String) -> String {
        "body-index-\(accountID)"
    }
    public static func thread(_ id: String) -> String { "thread-\(id)" }
    public static func body(_ messageID: String) -> String { "body-\(messageID)" }
    public static func labels(accountID: String) -> String { "labels-\(accountID)" }
}
