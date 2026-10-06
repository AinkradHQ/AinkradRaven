import Foundation

/// The one method `RavenViewModel` actually needs from `Outbox` — pulled out
/// into a protocol so a test can inject a fake that fails `enqueue`, without
/// a real `Outbox` (which only ever fails to persist on an encoding error,
/// not something a test can trigger through its public API) standing in the
/// way of exercising that path.
@MainActor public protocol MutationOutbox: AnyObject {
    /// `accountID` is the account the operation belongs to — the thread's
    /// account for a mutation, the composing account for a send. `nil` falls
    /// back to the outbox's own default stamp, which is only unambiguous while
    /// a single account is connected.
    @discardableResult
    func enqueue(_ operation: OutboxEntry.Operation, accountID: String?) throws -> UUID
}

extension MutationOutbox {
    @discardableResult
    public func enqueue(_ operation: OutboxEntry.Operation) throws -> UUID {
        try enqueue(operation, accountID: nil)
    }
}
