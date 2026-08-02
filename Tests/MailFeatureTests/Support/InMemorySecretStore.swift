import Foundation
import AinkradAppKit

/// Stands in for the host's Keychain-backed `PluginSecretStore`.
final class InMemorySecretStore: PluginSecretStore {
    private var storage: [String: String] = [:]

    func secret(forKey key: String) -> String? { storage[key] }

    func setSecret(_ value: String?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}
