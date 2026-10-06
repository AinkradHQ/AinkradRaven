import Foundation

/// The runtime's credential and account-connection surface: the OAuth client
/// getters, `saveCredentials`, the account list, the composing account and
/// `connectAccount`.
///
/// Split out of `RavenRuntime.swift` purely for length. Nothing here writes the
/// file-scoped `private(set)` state, which is why `signOut` and the outbox
/// snapshots stay in that file.
extension RavenRuntime {
    // MARK: Credentials

    /// The client id currently saved, if any — safe to show back in the field
    /// the user typed it into. There is deliberately no equivalent getter for
    /// the secret; see `clientSecretKey`.
    public var savedClientID: String? { providerFactory.savedClientID }

    public var hasCredentials: Bool { providerFactory.hasGmailCredentials }

    /// Whether `BakedOAuthCredentials` supplied both values at build time
    /// (see `scripts/generate-oauth-credentials.sh`). When true, the
    /// Accounts surface shows only the Connect button and the connected
    /// account — no manual client id/secret fields, since there is nothing
    /// for the user to enter.
    public var isCredentialsBaked: Bool { providerFactory.isCredentialsBaked }

    /// Whether Connect could possibly succeed: credentials are either baked
    /// into the app (the shipped case) or have been saved by the user.
    /// Enabled-but-guaranteed-to-fail is worse than disabled.
    ///
    /// Lives on the runtime rather than in a view because BOTH settings
    /// surfaces need it now — the catalog's Connect action and the fallback
    /// pane's button — and two copies of this rule is how one of them ends up
    /// offering a button that cannot work. Note it asks whether credentials are
    /// SAVED, not whether something is typed: on the catalog surface saving is
    /// its own explicit action (`Save client credentials`), so "typed but not
    /// saved" is no longer a state Connect should accept.
    public var canConnectAccount: Bool { isCredentialsBaked || hasCredentials }

    /// Unchanged semantics: the id is persisted as a document, the secret goes
    /// to `host.secrets` only, and every stored account is re-attached with the
    /// new client. Both halves now happen inside `ProviderFactory`, which is
    /// the only thing that changed here.
    public func saveCredentials(clientID: String, clientSecret: String) {
        providerFactory.saveGmailCredentials(clientID: clientID, clientSecret: clientSecret)
        attachStoredAccounts()
    }

    // MARK: Accounts

    public var accounts: [MailAccount] { store.accounts() }

    /// The account a freshly composed message (not a reply — a reply takes its
    /// thread's account) goes out from: the Inbox's account filter if the user
    /// has chosen one, otherwise the only connected account.
    ///
    /// Deliberately `nil` when several accounts are connected and none is
    /// chosen, rather than falling back to `accounts.first`. An unattributed
    /// message stays queued instead of being transmitted from an arbitrary
    /// mailbox, and Compose says so — the from-account picker that removes the
    /// ambiguity is the UI half of this milestone. Nothing changes while a
    /// single account is connected.
    public var composingAccountID: String? {
        if let chosen = model.accountID { return chosen }
        return providers.sole?.accountID
    }

    /// True when `accountID`'s attached provider declares `.readOnly` (an
    /// imported Apple Mail mailbox, which has no transport to send or mutate
    /// through). `false` for an account with no provider attached at all —
    /// callers that need "attached AND read-write" already check attachment
    /// separately (`composingAccountID`, `accounts`), so this only answers
    /// the capability question.
    public func isReadOnly(accountID: String) -> Bool {
        providers.provider(for: accountID)?.capabilities == .readOnly
    }

    /// Runs the loopback OAuth flow, saves the resulting account, attaches
    /// its provider, and returns — WITHOUT waiting for the 90-day backfill
    /// that follows. The account is already saved as `.syncing` by the time
    /// this returns, so the Connect button's `Task` completes as soon as the
    /// browser sign-in itself finishes, not a minute later once every thread
    /// in the window has been fetched. The backfill itself runs as a
    /// separate, detached task (`startBackfill()`) that publishes progress
    /// into `syncState`/`model` as it goes — see that method's documentation.
    /// `onAuthorizationURL` lets the caller present the URL if the browser
    /// doesn't visibly pop (see `GmailAuth.authorize`).
    ///
    /// `kind` defaults to `.gmail`, which is the only kind with an interactive
    /// flow today — the existing Connect button therefore behaves exactly as
    /// before. Both the sign-in and the provider come from `ProviderFactory`,
    /// so the account's kind is now recorded from the argument rather than
    /// hardcoded, and a kind whose flow does not exist yet fails with
    /// `MailError.unsupportedProvider` *before* anything is saved.
    public func connectAccount(
        kind: MailAccount.ProviderKind = .gmail,
        onAuthorizationURL: (@Sendable (URL) -> Void)? = nil
    ) async throws {
        let (accountID, address) = try await providerFactory.authorize(
            kind: kind, onAuthorizationURL: onAuthorizationURL)
        let account = MailAccount(
            id: accountID, provider: kind, address: address,
            displayName: address, state: .syncing)
        try store.saveAccount(account)
        attach(provider: try providerFactory.makeProvider(for: account), accountID: accountID)
        // Deliberately does NOT scope the Inbox to the account just added:
        // connecting a second mailbox must not hide the first one. The unified
        // list (`model.accountID == nil`) covers every account; a per-account
        // filter is the user's choice, not a side effect of signing in.
        model.reload()
        startBackfill(accountID: accountID)
    }
}
