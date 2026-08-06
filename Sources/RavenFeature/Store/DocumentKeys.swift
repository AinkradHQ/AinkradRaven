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
    /// Removed on sign-out by `DocumentMailStore.purge(accountID:)`, alongside
    /// `appleMailDirectory` and `imapMailboxes`; the app password it points at is
    /// cleared by `ProviderFactory.signOut` through `IMAPAppPasswordStore.clear`.
    public static func imapSettings(accountID: String) -> String {
        "imap-settings-\(accountID)"
    }

    /// An `.imap` account's `LIST`ed mailbox set (`IMAPMailboxDirectory`), written
    /// when the account is added and refreshed on **every session acquire**
    /// thereafter (`ProviderFactory.recordMailboxDirectory`) — which is what stops
    /// it drifting away from the live directory `IMAPProvider.applyLabels` resolves
    /// move destinations from. `testIMAPConnection` deliberately writes nothing: it
    /// runs before there is an account to key this by.
    ///
    /// Persisted because `LabelVocabularyResolver` is static and has no session:
    /// without a stored directory it cannot build an `IMAPVocabulary`, so every IMAP
    /// mutation is refused. Folder *names*, not credentials — the same category as
    /// `appleMailDirectory`. Removed by `DocumentMailStore.purge(accountID:)`.
    public static func imapMailboxes(accountID: String) -> String {
        "imap-mailboxes-\(accountID)"
    }

    /// One month's `label_with_reason` records for an account (see
    /// `LabelReason`). Sharded by month exactly like `index(accountID:month:)`,
    /// and for the same reason: the window is 90 days, so a read never has to
    /// load more than four documents and expiry is a shard the purge drops.
    ///
    /// Local-only audit data — it is deliberately not part of any
    /// `LabelMutation` and never reaches a provider. Removed by
    /// `DocumentMailStore.purge(accountID:)`, alongside `imapSettings` and
    /// `imapMailboxes`.
    public static func labelReasons(accountID: String, month: String) -> String {
        "label-reasons-\(accountID)-\(month)"
    }

    /// The month shards a reason log has written, for the same reason
    /// `indexMonths` exists: the host's document store cannot enumerate keys, so
    /// without this registry a sign-out purge has no way to find the reason
    /// shards it must delete — and `applemail-directory-<id>`,
    /// `imap-settings-<id>` and the IMAP app password all shipped unpurged
    /// before this rule was written down.
    public static func labelReasonMonths(accountID: String) -> String {
        "label-reason-months-\(accountID)"
    }
}
