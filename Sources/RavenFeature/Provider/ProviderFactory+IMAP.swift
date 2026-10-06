import Foundation

/// `ProviderFactory`'s IMAP half: building an `IMAPProvider` from stored
/// settings, the closures it is handed (stored locators, mailbox-directory
/// refresh, SMTP submission), and account setup (`imapAccountID`,
/// `saveIMAPAccount`, `probeIMAP`).
///
/// Split out of `ProviderFactory.swift` purely for length. `openIMAPSession`
/// stays in that file because it is a stored property.
extension ProviderFactory {
    /// Rebuilds an `IMAPProvider` from the server settings saved when the account
    /// was added, plus the app password held in `host.secrets`.
    ///
    /// The connection is established **lazily**, inside the closure the provider
    /// calls per operation, and not here: `makeProvider` is synchronous and is
    /// re-run for every account by `attachStoredAccounts()` on every credential
    /// change, so opening a socket here would connect to every IMAP server the user
    /// has just to render the Accounts list.
    ///
    /// The lease caches nothing on purpose either — see `IMAPProvider.acquire`. A
    /// cached session would have to answer "is this socket still alive", and the honest
    /// answer at this layer is a fresh connect; Task 14's IDLE work is where a
    /// long-lived session gets an owner that can tell. Note that caching and *closing*
    /// are separate questions: whatever Task 14 does about reuse, the lease's `release`
    /// is what returns the connection slot, and it runs after every operation.
    func makeIMAPProvider(for account: MailAccount) throws -> MailProvider {
        guard let data = host.documents.data(forKey: DocumentKeys.imapSettings(accountID: account.id)),
            let settings = try? JSONDecoder().decode(IMAPAccountSettings.self, from: data),
            let credential = IMAPAppPasswordStore.credential(
                accountID: account.id, username: settings.username, secrets: host.secrets)
        else {
            // No settings row, or no stored password: this ONE account cannot be
            // built, reported by id like every other unbuildable account.
            throw MailError.unsupportedProvider(
                kind: account.provider.identifier,
                accountID: account.id)
        }
        let open = openIMAPSession
        let accountID = account.id
        return IMAPProvider(
            accountID: account.id,
            submit: smtpSubmit(
                settings: settings, credential: credential,
                sender: account.address),
            // Rebuilds a thread's locators from the store when the provider's
            // in-memory index has never seen it — i.e. after every relaunch. See
            // `IMAPProvider.storedLocators`; without this, `applyLabels` had no
            // UIDs to act on and an archive silently never reached the server.
            //
            // `MailMessage.id` for an IMAP message IS the encoded locator, so this
            // is a decode, not a second index that could disagree with the first.
            // Non-IMAP ids (a Gmail id on a thread that predates this account's
            // migration, a truncated string) decode to `nil` and are dropped:
            // `IMAPMessageLocator(encoded:)` refuses rather than guessing a UID.
            //
            // Hops to the factory rather than capturing `host.documents`:
            // `PluginDocumentStore` is not `Sendable`, and this closure is. The
            // factory is `@MainActor`, which is where the document store is already
            // confined, so the hop is the isolation the type actually has rather
            // than a lock bolted on.
            storedLocators: { @Sendable [weak self] threadID in
                await self?.locators(threadID: threadID) ?? []
            }
        ) {
            [weak self] in
            let working = try await open(settings, credential)
            await self?.recordMailboxDirectory(working.directory, accountID: accountID)
            // The release is bound to THIS session, so `withSession` cannot log out of
            // somebody else's, and every acquire here has exactly one.
            return IMAPSessionLease(working: working) {
                await IMAPProvider.closeSession(working)
            }
        }
    }

    /// A stored thread's IMAP locators, decoded from its message ids.
    ///
    /// `MailMessage.id` for an IMAP message IS `IMAPMessageLocator.encoded`, so
    /// this is a decode rather than a second index that could drift from the first.
    /// Ids this build did not mint — a Gmail id, a truncated string — decode to
    /// `nil` and are dropped, because `IMAPMessageLocator(encoded:)` refuses rather
    /// than guessing a UID, and acting on a guessed UID would mutate somebody
    /// else's message.
    private func locators(threadID: String) -> [IMAPMessageLocator] {
        DocumentMailStore(documents: host.documents).thread(threadID)?
            .messages.compactMap { IMAPMessageLocator(encoded: $0.id) } ?? []
    }

    /// Writes the mailbox list this session just `LIST`ed over the persisted one.
    ///
    /// **This is what keeps the vocabulary and the move destination from
    /// disagreeing**, and the failure it prevents is losing mail into the wrong
    /// folder rather than a stale-looking list. `IMAPProvider.applyLabels` resolves
    /// its move *destination* from the live `working.directory`, while
    /// `LabelVocabularyResolver` renders the mutation from the *persisted* one. If
    /// the persisted copy predates a Trash folder the user has since created,
    /// `IMAPVocabulary.label(for: .trash)` answers `nil`, `render` drops it,
    /// `ThreadAction.trash` arrives as a bare `remove: ["INBOX"]` — which is
    /// byte-identical to an archive — and the message is moved to **Archive instead
    /// of Trash**, with no error anywhere. Refreshing here means every operation
    /// after the first sees the mailboxes the server actually has.
    ///
    /// Written from the acquire, not from account setup alone, because that is the
    /// one place a fresh `LIST` already exists: `openSession` performs it once per
    /// session regardless, so this costs no round trip.
    ///
    /// **The residual window, stated rather than implied:** a folder created between
    /// the moment a mutation is rendered and the moment the session is acquired is
    /// still missed for that one action. Rendering happens upstream of the provider
    /// (`ThreadMutationApplier`, the outbox), so no write here can close that gap;
    /// what it closes is the unbounded one, where the persisted list was written
    /// once at account-add and never again.
    ///
    /// A second `DocumentMailStore` over the same `host.documents` rather than a
    /// reference to the runtime's: that type holds no cached state — a
    /// `PluginDocumentStore`, a coder pair, and a diagnostic key — so two instances
    /// read and write the same bytes, and this keeps the key name and the encoding
    /// in the one type that owns them instead of duplicating both here.
    private func recordMailboxDirectory(
        _ directory: IMAPMailboxDirectory,
        accountID: String
    ) {
        // Best effort: a failed write must never fail the operation the session was
        // acquired for. The consequence of a miss is one more stale read, which is
        // the state this whole method is improving on, not a new failure mode.
        try? DocumentMailStore(documents: host.documents)
            .saveIMAPMailboxDirectory(directory, accountID: accountID)
    }

    /// How this account submits mail, or `nil` when no SMTP server is configured.
    ///
    /// Built here rather than inside `IMAPProvider` because this is the file that
    /// holds the credential path: the provider receives a closure it can call and
    /// never an `IMAPCredential`, so no part of the read/write path can reach the
    /// password even by accident.
    private func smtpSubmit(
        settings: IMAPAccountSettings, credential: IMAPCredential,
        sender: String
    )
        -> (@Sendable (OutgoingMessage) async throws -> String)?
    {
        guard let endpoint = settings.smtpEndpoint else { return nil }
        let submitter = SMTPSubmitter(
            endpoint: endpoint, sender: sender,
            credential: credential)
        return { try await submitter.submit($0) }
    }

    // MARK: IMAP account setup

    /// A stable account id for an IMAP mailbox.
    ///
    /// Derived from the login rather than random, so re-adding the same mailbox
    /// **replaces** it instead of producing a second account row pointing at the
    /// same server — which would then be backfilled twice into two sets of shards.
    /// Lowercased because IMAP usernames and hostnames are compared
    /// case-insensitively by every server this targets.
    static func imapAccountID(settings: IMAPAccountSettings) -> String {
        "imap-\(settings.username.lowercased())@\(settings.host.lowercased())"
    }

    /// Persists one IMAP account's server settings and its app password, each to
    /// the store that is right for it.
    ///
    /// The split is the whole point and is asserted structurally by
    /// `IMAPAccountSetupTests`: `settings` (host, port, TLS mode, username) is a
    /// *location* and goes to `host.documents`; `password` is a credential and goes
    /// to `host.secrets` through `IMAPAppPasswordStore` and nowhere else. This
    /// function is the only place in the app that writes an IMAP app password.
    func saveIMAPAccount(
        settings: IMAPAccountSettings, password: String,
        accountID: String
    ) throws {
        host.documents.setData(
            try JSONEncoder().encode(settings),
            forKey: DocumentKeys.imapSettings(accountID: accountID))
        IMAPAppPasswordStore.store(password, accountID: accountID, secrets: host.secrets)
    }

    /// Opens a session with the given settings and password *without* persisting
    /// either, and returns the mailboxes the server listed.
    ///
    /// Nothing is written before the server has accepted the credential, so a failed
    /// attempt leaves no account row, no settings document and no secret behind —
    /// there is no "half-added account" state to clean up.
    func probeIMAP(settings: IMAPAccountSettings, password: String) async
        -> Result<IMAPMailboxDirectory, IMAPAccountSetup.ConnectionFailure>
    {
        let credential = IMAPCredential.appPassword(
            username: settings.username,
            password: password)
        do {
            let working = try await openIMAPSession(settings, credential)
            let directory = working.directory
            await IMAPProvider.closeSession(working)
            return .success(directory)
        } catch {
            return .failure(IMAPAccountSetup.classify(error))
        }
    }
}
