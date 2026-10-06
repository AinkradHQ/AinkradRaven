import os

/// A value behind a lock, boxed in a class so a `@Sendable` closure — a
/// `StubURLProtocol` handler, a task-group child, a provider-factory hook — can
/// capture it and share one copy.
///
/// `OSAllocatedUnfairLock` rather than `Synchronization.Mutex`: `Mutex` needs
/// macOS 15 and this target deploys to 14.
final class Locked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    /// A snapshot of the current value.
    var value: Value { lock.withLock { $0 } }

    @discardableResult
    func withLock<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        lock.withLock(body)
    }
}
