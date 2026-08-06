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

    /// Everything held, so a test can assert the store's contents EXHAUSTIVELY
    /// rather than key by key. Checking known keys can only prove what is
    /// present; the interesting question for a credential store is what else
    /// got written next to it.
    func allSecrets() -> [String: String] { storage }
}
