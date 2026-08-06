import Foundation
import AinkradAppKit

/// Adding and testing an IMAP account — the runtime half of Task 16.
///
/// A separate file rather than more of `RavenRuntime.swift`, which sits seven lines
/// under the repo's hard 500-line cap. Nothing here is new *state*: the two methods
/// below write only through paths that already existed (`store.saveAccount`,
/// `attach`, `startBackfill`, `providerFactory`), so the "every stored property and
/// the account lifecycle live in one file" rule is bent only for the lifecycle, and
/// the narrow write surface documented under that file's "State mutation" heading
/// needed no new mutator.
extension RavenRuntime {

    /// Whether an IMAP account can be added at all. Unconditionally true, and
    /// stated rather than left implicit: unlike Gmail, IMAP needs no OAuth client,
    /// so `canConnectAccount` — which asks whether Gmail credentials are saved —
    /// must not gate this form. Gating it that way is how "connect any mailbox"
    /// would end up requiring a Google API project.
    public var canAddIMAPAccount: Bool { true }

    /// Connects with the given settings and password *without saving anything*, and
    /// reports either the number of mailboxes the server listed or a typed failure.
    ///
    /// The mailbox count is the return value on purpose: it is the one piece of
    /// evidence that distinguishes "authenticated" from "authenticated and can
    /// actually see mail", and an account whose `LIST` is empty cannot have a
    /// working archive or trash (see `LabelVocabularyResolver.imapVocabulary`).
    func testIMAPConnection(settings: IMAPAccountSettings, password: String) async
        -> Result<Int, IMAPAccountSetup.ConnectionFailure> {
        switch await providerFactory.probeIMAP(settings: settings, password: password) {
        case .success(let directory): return .success(directory.mailboxes.count)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Adds an IMAP account, in an order chosen so that no failure leaves a partial
    /// account behind.
    ///
    /// 1. **Connect first, save nothing.** The server has to accept the password and
    ///    answer `LIST` before a single document or secret is written. A wrong
    ///    password therefore leaves the app exactly as it was — no account row for
    ///    the user to delete, no orphan secret in the Keychain.
    /// 2. **Then the credential and the settings**, through
    ///    `ProviderFactory.saveIMAPAccount`, which is the only writer of either.
    /// 3. **Then the mailbox directory**, which is what makes
    ///    `LabelVocabularyResolver` able to answer for this account — until it is
    ///    stored, every IMAP mutation is refused, so this is not bookkeeping.
    /// 4. **Then the account row**, the provider, and the detached backfill —
    ///    the same last three steps `connectAccount` performs for Gmail.
    ///
    /// Re-adding a mailbox already connected replaces it rather than duplicating it;
    /// see `ProviderFactory.imapAccountID`.
    ///
    /// - Returns: the id of the account added.
    @discardableResult
    func addIMAPAccount(address: String, settings: IMAPAccountSettings,
                        password: String) async throws -> String {
        let directory: IMAPMailboxDirectory
        switch await providerFactory.probeIMAP(settings: settings, password: password) {
        case .success(let listed): directory = listed
        case .failure(let failure): throw failure
        }

        let accountID = ProviderFactory.imapAccountID(settings: settings)
        try providerFactory.saveIMAPAccount(settings: settings, password: password,
                                            accountID: accountID)
        try store.saveIMAPMailboxDirectory(directory, accountID: accountID)

        let account = MailAccount(id: accountID, provider: .imap, address: address,
                                  displayName: address, state: .syncing)
        try store.saveAccount(account)
        attach(provider: try providerFactory.makeProvider(for: account), accountID: accountID)
        // Same rule as `connectAccount`: adding a mailbox must not scope the Inbox
        // to it and hide the ones already connected.
        model.reload()
        startBackfill(accountID: accountID)
        return accountID
    }
}
