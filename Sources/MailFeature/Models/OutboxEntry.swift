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

    public init(id: UUID = UUID(), operation: Operation, attempts: Int = 0,
                lastError: String? = nil, isDeadLettered: Bool = false,
                queuedAt: Date = Date()) {
        self.id = id; self.operation = operation; self.attempts = attempts
        self.lastError = lastError; self.isDeadLettered = isDeadLettered
        self.queuedAt = queuedAt
    }
}
