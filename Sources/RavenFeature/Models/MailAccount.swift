import Foundation

public struct MailAccount: Codable, Equatable, Sendable, Identifiable {
    public enum ProviderKind: String, Codable, Sendable { case gmail }
    public enum State: String, Codable, Sendable {
        case needsAuth, syncing, ready, failed
    }

    public let id: String
    public let provider: ProviderKind
    public var address: String
    public var displayName: String
    /// Gmail `historyId`. Nil until the first backfill completes.
    public var syncCursor: String?
    public var state: State
    public var lastSyncedAt: Date?
    public var lastError: String?
    public var signature: String

    public init(id: String, provider: ProviderKind, address: String,
                displayName: String, syncCursor: String? = nil,
                state: State = .needsAuth, lastSyncedAt: Date? = nil,
                lastError: String? = nil, signature: String = "") {
        self.id = id; self.provider = provider; self.address = address
        self.displayName = displayName; self.syncCursor = syncCursor
        self.state = state; self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError; self.signature = signature
    }
}
