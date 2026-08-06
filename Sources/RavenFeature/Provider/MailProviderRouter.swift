import Foundation

/// Which `MailProvider` belongs to which account, in one place.
///
/// M0 held exactly one attached provider behind a forwarding proxy, because
/// exactly one account could be connected. With several accounts connected,
/// "the provider" is no longer a single thing: the outbox must transmit each
/// entry through the account that composed it, and an archive search with no
/// `account_id` must reach every account. Both of those need a *lookup*, not a
/// current-value, so the lookup lives here rather than being re-derived by
/// each caller.
///
/// `@MainActor` on purpose: every caller (`RavenRuntime`, `Outbox`,
/// `RavenMCPOperations`) is already main-actor isolated, so the table needs no
/// locking and the compiler — rather than a convention comment — is what keeps
/// it from being touched off-actor. The `MailProvider` values it hands out are
/// plain `Sendable`, exactly as before.
@MainActor public final class MailProviderRouter {
    private var providers: [String: MailProvider] = [:]

    /// True only for the single-provider convenience init below. When set,
    /// `provider(for:)` answers with the one attached provider whatever
    /// account id it is asked about — the behaviour a test double built around
    /// one `FakeMailProvider` needs, and the behaviour the M0 single-account
    /// proxy had. The real runtime never sets it, so a production lookup is
    /// always an exact per-account match.
    public let acceptsAnyAccount: Bool

    public init() { acceptsAnyAccount = false }

    /// A router around exactly one provider, which answers for any account id.
    /// Used by `Outbox`'s single-provider convenience init (and therefore by
    /// tests); the runtime always builds the multi-account form above and
    /// `attach`es per account.
    public init(single provider: MailProvider) {
        acceptsAnyAccount = true
        providers[provider.accountID] = provider
    }

    public func attach(_ provider: MailProvider, accountID: String) {
        providers[accountID] = provider
    }

    /// Removes one account's provider and leaves every other account attached
    /// — the sign-out path. Never clears the whole table.
    public func detach(accountID: String) {
        providers.removeValue(forKey: accountID)
    }

    public func provider(for accountID: String) -> MailProvider? {
        if let exact = providers[accountID] { return exact }
        return acceptsAnyAccount ? sole : nil
    }

    /// The provider for `accountID`, refusing up front if it cannot mutate.
    ///
    /// Every send/label-mutation routing path (`Outbox.drain()`,
    /// `RavenMCPOperations`'s mutation tools) must go through THIS rather than
    /// `provider(for:)` followed by an unconditional `send`/`applyLabels` —
    /// otherwise a read-only backend (Apple Mail import) would only be
    /// stopped by whichever call site remembered to check `capabilities`
    /// itself. Enforcing it here means every caller, present and future,
    /// gets the same refusal for free.
    ///
    /// Throws `.unknownAccount` when nothing is attached for `accountID` —
    /// the same case `provider(for:)`'s callers already map a `nil` onto —
    /// and `.readOnlyAccount` when a provider IS attached but declares
    /// `.readOnly`.
    public func writableProvider(for accountID: String) throws -> MailProvider {
        guard let provider = provider(for: accountID) else {
            throw MailError.unknownAccount(accountID)
        }
        guard provider.capabilities == .readWrite else {
            throw MailError.readOnlyAccount(accountID)
        }
        return provider
    }

    /// The one attached provider when there is exactly one, otherwise `nil`.
    /// Used where an operation has no account to key on (an outbox entry
    /// queued before any account was known) and guessing between two accounts
    /// would be worse than refusing.
    public var sole: MailProvider? {
        providers.count == 1 ? providers.values.first : nil
    }

    /// Sorted so a multi-account fan-out (archive search across every account)
    /// is deterministic rather than dictionary-ordered.
    public var attachedAccountIDs: [String] { providers.keys.sorted() }

    public var isEmpty: Bool { providers.isEmpty }
}
