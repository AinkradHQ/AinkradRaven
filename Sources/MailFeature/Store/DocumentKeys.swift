import Foundation

/// Every `PluginDocumentStore` key the app writes, in one place, so a rename
/// is one edit and a migration can enumerate them.
public enum DocumentKeys {
    public static let accounts = "accounts"
    public static let outbox = "outbox"
    public static func index(accountID: String, month: String) -> String {
        "index-\(accountID)-\(month)"
    }
    public static func thread(_ id: String) -> String { "thread-\(id)" }
    public static func body(_ messageID: String) -> String { "body-\(messageID)" }
    public static func labels(accountID: String) -> String { "labels-\(accountID)" }
}
