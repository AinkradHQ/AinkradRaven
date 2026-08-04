import Foundation
import AinkradAppKit

/// What Raven proves its identity with on an IMAP (and, in Task 15, SMTP)
/// connection.
///
/// A **value**, deliberately: it is produced on the main actor by whoever can
/// reach the host's Keychain (`IMAPAppPasswordStore`) or the OAuth token endpoint
/// (`IMAPOAuthCredentialSource`), and only then handed to `IMAPAuthenticator`.
/// The consequence is that nothing on the authentication path holds a
/// `PluginSecretStore`, let alone a `PluginDocumentStore` — there is no store
/// reference in `IMAPAuth.swift` at all, so no code there can be misdirected at
/// document storage. `IMAPAuthTests` asserts that structurally over the source
/// text.
///
/// Both cases carry secret material, so this type is intentionally NOT
/// `CustomStringConvertible`/`CustomDebugStringConvertible`-friendly by accident:
/// `redactedDescription` is the only string form, and the enum is not
/// `Equatable` so a failing `#expect` cannot print it either.
enum IMAPCredential: Sendable {
    /// A provider-issued app-specific password. Lives in `host.secrets` and
    /// nowhere else on disk.
    case appPassword(username: String, password: String)
    /// An OAuth 2.0 bearer access token for the `XOAUTH2` SASL mechanism. Held in
    /// memory only, for its lifetime; the *refresh* token is what persists, and
    /// it persists in `host.secrets`.
    case xoauth2(username: String, accessToken: String)

    var username: String {
        switch self {
        case .appPassword(let username, _), .xoauth2(let username, _): return username
        }
    }

    /// The only string form. Names the mechanism and the account, never the
    /// secret. Used by `IMAPAuthError` so an error string cannot carry a
    /// credential.
    var redactedDescription: String {
        switch self {
        case .appPassword(let username, _): return "app-password(\(username))"
        case .xoauth2(let username, _): return "xoauth2(\(username))"
        }
    }
}

/// Reads and writes the app password in the host's Keychain-backed secret store.
///
/// Separate from `IMAPAuthenticator` on purpose: this is the *only* type on the
/// IMAP path that knows a secret key name, and it is `@MainActor` because
/// `PluginSecretStore` is not `Sendable`. Authentication itself runs against an
/// actor-isolated session and therefore cannot hold the store even if someone
/// tried.
@MainActor
enum IMAPAppPasswordStore {
    /// One key per account, namespaced away from Gmail's `refresh-<id>` keys so
    /// two accounts with the same address on different provider kinds cannot
    /// collide.
    static func key(accountID: String) -> String { "imap-app-password-\(accountID)" }

    /// - Returns: nil when no password has been stored for the account. Callers
    ///   surface that as `MailError.notAuthenticated`, never as an empty password
    ///   attempt.
    static func credential(accountID: String, username: String,
                           secrets: any PluginSecretStore) -> IMAPCredential? {
        guard let password = secrets.secret(forKey: key(accountID: accountID)),
              !password.isEmpty else { return nil }
        return .appPassword(username: username, password: password)
    }

    static func store(_ password: String, accountID: String, secrets: any PluginSecretStore) {
        secrets.setSecret(password, forKey: key(accountID: accountID))
    }

    static func clear(accountID: String, secrets: any PluginSecretStore) {
        secrets.setSecret(nil, forKey: key(accountID: accountID))
    }
}

/// Turns a stored refresh token into a short-lived `XOAUTH2` credential through
/// Task 4's provider-neutral `OAuthTokenClient`.
///
/// The split of what persists where is the whole point of this type:
/// - refresh token → `host.secrets`, written here, read here;
/// - access token → this object's memory, keyed by account, expiring;
/// - neither → any document, any log, any error string.
@MainActor
final class IMAPOAuthCredentialSource {
    /// Refreshed this far before the server would reject it, so a token does not
    /// expire between the check and the `AUTHENTICATE`.
    private static let earlyRefresh: TimeInterval = 120

    private let client: OAuthTokenClient
    private let secrets: any PluginSecretStore
    /// In memory only. Never persisted, never logged. Readable inside the module
    /// so `IMAPAuthTests` can assert the access token is *here* and not in the
    /// secret store.
    private(set) var accessTokens: [String: (token: String, expiry: Date)] = [:]

    init(client: OAuthTokenClient, secrets: any PluginSecretStore) {
        self.client = client
        self.secrets = secrets
    }

    static func refreshTokenKey(accountID: String) -> String { "imap-refresh-\(accountID)" }

    func storeRefreshToken(_ token: String, accountID: String) {
        secrets.setSecret(token, forKey: Self.refreshTokenKey(accountID: accountID))
    }

    func signOut(accountID: String) {
        secrets.setSecret(nil, forKey: Self.refreshTokenKey(accountID: accountID))
        accessTokens.removeValue(forKey: accountID)
    }

    /// A usable credential, refreshing the access token only when the cached one
    /// is missing or close to expiry.
    func credential(accountID: String, username: String,
                    now: Date = Date()) async throws -> IMAPCredential {
        if let cached = accessTokens[accountID],
           cached.expiry.timeIntervalSince(now) > Self.earlyRefresh {
            return .xoauth2(username: username, accessToken: cached.token)
        }
        guard let refresh = secrets.secret(forKey: Self.refreshTokenKey(accountID: accountID)) else {
            throw MailError.notAuthenticated(accountID: accountID)
        }
        let payload = try await client.refresh(refreshToken: refresh)
        accessTokens[accountID] = (payload.accessToken, now.addingTimeInterval(payload.expiresIn))
        // A rotated refresh token replaces the stored one; dropping it would make
        // the next refresh fail an hour later, live-only, and silently.
        if let rotated = payload.refreshToken { storeRefreshToken(rotated, accountID: accountID) }
        return .xoauth2(username: username, accessToken: payload.accessToken)
    }
}
