import Foundation
import AinkradAppKit

/// Stands in for the host's `PluginDocumentStore`. Records writes so tests can
/// assert on sharding rather than only on read-back.
final class InMemoryDocumentStore: PluginDocumentStore {
    private(set) var storage: [String: Data] = [:]
    private(set) var writeLog: [String] = []

    func data(forKey key: String) -> Data? { storage[key] }

    func setData(_ data: Data?, forKey key: String) {
        writeLog.append(key)
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
}
