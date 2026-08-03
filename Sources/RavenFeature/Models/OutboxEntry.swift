import Foundation

public struct OutboxEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Operation: Codable, Equatable, Sendable {
        case labels(LabelMutation)
        case send(OutgoingMessage)
    }

    public let id: UUID
    public let operation: Operation
    public var attempts: Int
    public var lastError: String?
    public var isDeadLettered: Bool
    public let queuedAt: Date
    /// Set immediately before the operation is handed to the provider, and
    /// persisted before the call is made. If a fresh process finds this set on
    /// load, the previous process died mid-operation and the outcome (did the
    /// email actually go out?) is unknown — see `Outbox`'s init for how that is
    /// handled.
    public var inFlightAt: Date?
    /// True when this entry's outcome is unknown (see `inFlightAt`) and it has
    /// been pulled out of `pending()` for a human to resolve, rather than being
    /// guessed at automatically.
    public var needsReview: Bool
    /// The account this operation belongs to, stamped by `Outbox.enqueue` from
    /// the outbox's current account. `OutgoingMessage` itself carries no
    /// account, so without this a send queued while account A was connected
    /// would transmit from account B the moment a different account signed in
    /// — the wrong mailbox, and irreversible for a `.send`. `nil` means
    /// "queued before any account was known"; those stay eligible, since there
    /// is no account they could be crossing over from.
    public var accountID: String?

    public init(id: UUID = UUID(), operation: Operation, attempts: Int = 0,
                lastError: String? = nil, isDeadLettered: Bool = false,
                queuedAt: Date = Date(), inFlightAt: Date? = nil,
                needsReview: Bool = false, accountID: String? = nil) {
        self.id = id; self.operation = operation; self.attempts = attempts
        self.lastError = lastError; self.isDeadLettered = isDeadLettered
        self.queuedAt = queuedAt; self.inFlightAt = inFlightAt
        self.needsReview = needsReview; self.accountID = accountID
    }
}
