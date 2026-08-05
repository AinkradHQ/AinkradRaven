import Foundation

/// Every `PluginDocumentStore` key the app writes, in one place, so a rename
/// is one edit and a migration can enumerate them.
public enum DocumentKeys {
    public static let accounts = "accounts"
    public static let outbox = "outbox"
    /// The user's filter/rules list (see `MailRule`/`RuleSet`). Preferences,
    /// not secrets, hence a plain document like `outbox` rather than
    /// `host.secrets`.
    public static let rules = "rules"
    /// Per-sender "Load images" opt-in — see `RemoteImageAllowList`. Not
    /// scoped per-account: the same sender address means the same person
    /// regardless of which of the user's own accounts received the mail.
    public static let remoteImageAllowList = "remote-image-allow-list"
    /// Surface translucency and blur choice — see `RavenAppearance`. A
    /// preference, so a plain document like `rules`, and NOT per-account: how
    /// see-through the reading pane is is a property of the window, not of
    /// whose mail is in it.
    public static let appearance = "appearance"
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
    /// The security-scoped bookmark (`MailDirectoryBookmark.data`) for an
    /// imported Apple Mail account's on-disk folder. A *location*, not a
    /// credential — nothing in it grants access to a remote mailbox — so a
    /// document rather than `host.secrets`, like `gmail-client-id`. Read by
    /// `ProviderFactory` to rebuild the `.appleMail` provider on relaunch and
    /// removed by `ProviderFactory.signOut`.
    public static func appleMailDirectory(accountID: String) -> String {
        "applemail-directory-\(accountID)"
    }

    /// An `.imap` account's server settings (`IMAPAccountSettings`): host, port and
    /// username. A *location plus a login name*, not a credential — the password
    /// lives under `IMAPAppPasswordStore.key(accountID:)` in `host.secrets` and never
    /// here — so a document, exactly like `gmail-client-id`. Read by
    /// `ProviderFactory` to rebuild the `.imap` provider on relaunch.
    ///
    /// Unlike `appleMailDirectory`, this is **not** removed by
    /// `ProviderFactory.signOut` yet, and neither is the app password
    /// (`IMAPAppPasswordStore.clear` has no production caller). Both belong with the
    /// account-setup work that writes them; stated here rather than left to be
    /// inferred from the absence of a line.
    public static func imapSettings(accountID: String) -> String {
        "imap-settings-\(accountID)"
    }
}
