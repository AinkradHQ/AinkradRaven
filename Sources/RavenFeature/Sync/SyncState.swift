import Foundation

/// What the Accounts surface renders. Kept separate from `MailAccount.state`
/// because this is transient UI progress, not persisted account status.
public enum SyncState: Equatable, Sendable {
    case idle
    case backfilling(threadsSynced: Int)
    case delta
    case failed(String)
}
