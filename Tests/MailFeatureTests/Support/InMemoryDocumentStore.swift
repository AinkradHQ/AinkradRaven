import Foundation
import AinkradAppKit

/// Stands in for the host's `PluginDocumentStore`. Records writes so tests can
/// assert on sharding rather than only on read-back.
final class InMemoryDocumentStore: PluginDocumentStore {
    private(set) var storage: [String: Data] = [:]
    private(set) var writeLog: [String] = []
    /// When set, the (dropWritesAfter + 1)-th and every later call to
    /// `setData` is silently dropped — the call is recorded in `writeLog` but
    /// `storage` is left untouched, simulating a write that never lands on
    /// disk (e.g. disk full) without the caller receiving a thrown error.
    var dropWritesAfter: Int?

    func data(forKey key: String) -> Data? { storage[key] }

    func setData(_ data: Data?, forKey key: String) {
        writeLog.append(key)
        if let threshold = dropWritesAfter, writeLog.count > threshold { return }
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
}
