import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Task 16's *lifecycle*: what adding an IMAP account writes and where, what
/// signing out removes, what the label resolver then answers, and the SMTP half
/// that had no production caller.
///
/// The rules half is `IMAPAccountSetupTests`.
///
/// Every runtime here calls `teardown()` immediately after `init` and again at the
/// end — the convention `MultiAccountTests` established — so neither the 120-second
/// poll loop nor the backfill/IDLE tasks that `addIMAPAccount` starts can outlive
/// the test.
@Suite("IMAP account lifecycle")
@MainActor struct IMAPAccountLifecycleTests {

    // MARK: - Harness

    /// Records what the production opener would have been handed, and answers with
    /// a scripted session over the real fixture mailbox list.
    ///
    /// `IMAPProviderHarness.directory()` is `imap-provider-list.txt`, where the
    /// archive is named **`Folder B`** and the trash **`Folder C`**. That is what
    /// makes the resolver assertions below non-vacuous: an implementation that
    /// guessed `"Archive"`/`"Trash"` instead of reading the persisted directory
    /// would produce a plausible-looking mutation aimed at mailboxes this account
    /// does not have, and every folder assertion here would fail.
    final class OpenerSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(settings: IMAPAccountSettings, username: String)] = []
        /// When set, every open fails with this instead of succeeding.
        var failure: (any Error)?
        /// What the scripted server `LIST`s. Settable so a test can model a folder
        /// the user creates AFTER the account was added — the case where the
        /// persisted directory and the live one drift apart.
        var directory: IMAPMailboxDirectory?

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        var lastSettings: IMAPAccountSettings? {
            lock.lock(); defer { lock.unlock() }; return calls.last?.settings
        }
        var lastUsername: String? {
            lock.lock(); defer { lock.unlock() }; return calls.last?.username
        }

        func record(_ settings: IMAPAccountSettings, _ username: String) {
            lock.lock(); calls.append((settings, username)); lock.unlock()
        }
    }

    /// Installs the spy as the factory's session opener and returns it.
    ///
    /// The scripted transport answers `LOGOUT` — which is the first and only command
    /// `probeIMAP` issues, since it lists nothing itself and hands the session
    /// straight to `IMAPProvider.closeSession`. Unscripted reads throw rather than
    /// suspend, so a command this harness did not expect fails the test instead of
    /// hanging it.
    static func installOpener(on runtime: RavenRuntime) -> OpenerSpy {
        let spy = OpenerSpy()
        runtime.providerFactory.openIMAPSession = { settings, credential in
            spy.record(settings, credential.username)
            if let failure = spy.failure { throw failure }
            let transport = ScriptedTransport()
            await transport.enqueue("* OK [CAPABILITY IMAP4rev1] ready\r\n")
            await transport.respond(to: "LOGOUT", with: "A0001 OK done\r\n")
            let session = IMAPSession(transport: transport)
            try await session.connect()
            return IMAPWorkingSession(
                session: session,
                directory: try spy.directory ?? IMAPProviderHarness.directory())
        }
        return spy
    }

    private func settings(tls: MailTransportTLS = .implicit,
                          withSMTP: Bool = true) -> IMAPAccountSettings {
        IMAPAccountSettings(
            host: "imap.example.test", port: tls == .implicit ? 993 : 143,
            username: "a@example.test", tls: tls,
            smtp: withSMTP ? SMTPAccountSettings(host: "smtp.example.test",
                                                 port: tls == .implicit ? 465 : 587,
                                                 tls: tls) : nil)
    }

    /// A torn-down runtime over a fake host, plus the two in-memory stores so a
    /// test can scan them exhaustively.
    private func runtime() -> (RavenRuntime, InMemoryDocumentStore, InMemorySecretStore) {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        return (runtime,
                host.documents as! InMemoryDocumentStore,
                host.secrets as! InMemorySecretStore)
    }

    /// Bounds an operation that goes through a session.
    ///
    /// Two independent stops, because they catch different things. The scripted
    /// transport is built with the default `.throwScriptExhausted`, so a command
    /// this harness did not script fails immediately instead of suspending — that
    /// covers a wrong expectation. This wall-clock cancel covers the other shape: a
    /// continuation that is never resumed at all, which no script can turn into an
    /// error. No passing test waits for it.
    private func bounded<T: Sendable>(_ label: String,
                                      sourceLocation: SourceLocation = #_sourceLocation,
                                      _ body: @MainActor @escaping () async throws -> T)
        async throws -> T {
        let work = Task { @MainActor in try await body() }
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            Issue.record("\(label) never resolved within 10s — the leaked-continuation shape",
                         sourceLocation: sourceLocation)
            work.cancel()
        }
        defer { deadline.cancel() }
        return try await work.value
    }

    // MARK: - The credential goes to secrets and nowhere else

    @Test("adding an account puts the app password in secrets and in no document")
    func passwordReachesSecretsOnly() async throws {
        let (runtime, documents, secrets) = self.runtime()
        let spy = Self.installOpener(on: runtime)
        let password = "app-pw-do-not-persist"

        let accountID = try await bounded("addIMAPAccount") {
            try await runtime.addIMAPAccount(address: "a@example.test",
                                             settings: self.settings(), password: password)
        }

        // In secrets, under this account's key and no other.
        #expect(secrets.allSecrets() == [IMAPAppPasswordStore.key(accountID: accountID): password])
        // And in NO document. Exhaustive over every byte the store holds, because
        // the interesting question is not "is it under the key I expected" but
        // "did it land anywhere at all".
        for (key, data) in documents.storage {
            #expect(!String(decoding: data, as: UTF8.self).contains(password),
                    "the app password reached document \(key)")
        }
        // The settings document exists and is readable — so the scan above is a
        // scan over real content, not over an empty store.
        let settingsData = try #require(
            documents.storage[DocumentKeys.imapSettings(accountID: accountID)])
        let stored = try JSONDecoder().decode(IMAPAccountSettings.self, from: settingsData)
        #expect(stored == settings())
        #expect(spy.lastUsername == "a@example.test")

        runtime.teardown()
    }

    @Test("nothing is written when the server refuses the credential")
    func aFailedAddWritesNothing() async throws {
        let (runtime, documents, secrets) = self.runtime()
        let spy = Self.installOpener(on: runtime)
        spy.failure = IMAPAuthError.rejected("Invalid credentials")
        let before = documents.storage

        await #expect(throws: IMAPAccountSetup.ConnectionFailure.auth("Invalid credentials")) {
            try await self.bounded("addIMAPAccount (refused)") {
                try await runtime.addIMAPAccount(address: "a@example.test",
                                                 settings: self.settings(), password: "wrong")
            }
        }

        // No half-added account: no secret, no settings row, no account row, and
        // the document store byte-identical to before the attempt.
        #expect(secrets.allSecrets().isEmpty)
        #expect(documents.storage == before)
        #expect(runtime.accounts.isEmpty)
        // Exactly one attempt: a refused credential must not be retried against
        // the server, which is how an account gets locked out.
        #expect(spy.callCount == 1)
        runtime.teardown()
    }

    @Test("test-connection reports the typed failure and saves nothing")
    func testConnectionIsTypedAndPure() async throws {
        let (runtime, documents, secrets) = self.runtime()
        let spy = Self.installOpener(on: runtime)

        spy.failure = MailTransportError.connectionFailed("refused")
        let hostFailure = try await bounded("testIMAPConnection (host)") {
            await runtime.testIMAPConnection(settings: self.settings(), password: "pw")
        }
        #expect(hostFailure.failureValue?.isHost == true)

        spy.failure = IMAPAuthError.rejected("bad password")
        let authFailure = try await bounded("testIMAPConnection (auth)") {
            await runtime.testIMAPConnection(settings: self.settings(), password: "pw")
        }
        #expect(authFailure.failureValue?.isAuth == true)

        spy.failure = nil
        // Four `LIST` lines in the fixture, including the `\Noselect` container:
        // the count is what the server said, not what is walkable.
        let listed = try await bounded("testIMAPConnection (ok)") {
            await runtime.testIMAPConnection(settings: self.settings(), password: "pw")
        }
        #expect(listed.successValue == 4)

        #expect(secrets.allSecrets().isEmpty)
        #expect(documents.storage[DocumentKeys.imapSettings(accountID: "x")] == nil)
        runtime.teardown()
    }

    @Test("the settings the opener is handed carry the user's TLS choice")
    func theOpenerSeesTheChosenTLSMode() async throws {
        let (runtime, _, _) = self.runtime()
        let spy = Self.installOpener(on: runtime)

        _ = try await bounded("testIMAPConnection (explicit)") {
            await runtime.testIMAPConnection(settings: self.settings(tls: .explicit),
                                             password: "pw")
        }
        #expect(spy.lastSettings?.tls == .explicit)
        #expect(spy.lastSettings?.port == 143)
        #expect(spy.lastSettings?.smtp?.port == 587)

        _ = try await bounded("testIMAPConnection (implicit)") {
            await runtime.testIMAPConnection(settings: self.settings(tls: .implicit),
                                             password: "pw")
        }
        #expect(spy.lastSettings?.tls == .implicit)
        #expect(spy.lastSettings?.port == 993)
        runtime.teardown()
    }

    // MARK: - The persisted mailbox list, and the resolver built on it

    @Test("the mailbox list is persisted per account and survives a reread")
    func mailboxListIsPersisted() async throws {
        let (runtime, documents, _) = self.runtime()
        _ = Self.installOpener(on: runtime)
        let accountID = try await bounded("addIMAPAccount") {
            try await runtime.addIMAPAccount(address: "a@example.test",
                                             settings: self.settings(), password: "pw")
        }

        #expect(documents.storage[DocumentKeys.imapMailboxes(accountID: accountID)] != nil)
        // Re-read through a SECOND store over the same documents, so this is a
        // round trip through the persisted bytes rather than a cached value.
        let reread = DocumentMailStore(documents: documents)
        let directory = try #require(reread.imapMailboxDirectory(accountID: accountID))
        #expect(directory.mailboxes.map(\.name) == ["INBOX", "Folder B", "Folder C", "Folder D"])
        // The canonical meanings are recomputed on decode, not stored — and they
        // are the fixture's deliberately unguessable ones.
        #expect(directory.mailbox(for: .archive)?.name == "Folder B")
        #expect(directory.mailbox(for: .trash)?.name == "Folder C")
        // `Folder D` is `\Noselect`, so it is kept in the list and excluded from
        // selection — a decode that dropped `attributes` would lose that.
        #expect(directory.mailboxes.last?.isSelectable == false)
        runtime.teardown()
    }

    @Test("the resolver answers for an IMAP account with a stored directory")
    func resolverAnswersFromTheStoredDirectory() async throws {
        let (runtime, _, _) = self.runtime()
        _ = Self.installOpener(on: runtime)
        let accountID = try await bounded("addIMAPAccount") {
            try await runtime.addIMAPAccount(address: "a@example.test",
                                             settings: self.settings(), password: "pw")
        }

        let vocabulary = try #require(
            LabelVocabularyResolver.vocabulary(forAccountID: accountID, store: runtime.store))
        // Archiving is the mutation the refusal existed to protect: it must render
        // to a MOVE into the account's real archive mailbox.
        #expect(vocabulary.label(for: .archive) == "Folder B")
        #expect(vocabulary.label(for: .trash) == "Folder C")
        #expect(vocabulary.label(for: .inbox) == "INBOX")
        // The IMAP-specific inversion is intact through the resolver, not just in
        // a directly-constructed vocabulary.
        #expect(vocabulary.label(for: .unread) == "\\Unseen")
        runtime.teardown()
    }

    @Test("the resolver still refuses when the directory is empty or absent")
    func resolverRefusesWithoutARealDirectory() throws {
        let (runtime, _, _) = self.runtime()
        let account = MailAccount(id: "imap-1", provider: .imap, address: "a@example.test",
                                  displayName: "a", state: .ready)
        try runtime.store.saveAccount(account)

        // Absent: nothing was ever listed for this account.
        #expect(LabelVocabularyResolver.vocabulary(forAccountID: "imap-1",
                                                   store: runtime.store) == nil)
        // Present but EMPTY — the dangerous case, not the harmless one. An
        // `IMAPVocabulary` over an empty directory answers nil for every folder
        // flag, so `render` drops them and `ThreadAction.archive` becomes an empty
        // mutation the UI reports as a successful archive.
        try runtime.store.saveIMAPMailboxDirectory(IMAPMailboxDirectory([]),
                                                   accountID: "imap-1")
        #expect(LabelVocabularyResolver.vocabulary(forAccountID: "imap-1",
                                                   store: runtime.store) == nil)
        // The rendering that refusal prevents, spelled out so the reason above is
        // observed rather than asserted in prose.
        let empty = IMAPVocabulary(directory: IMAPMailboxDirectory([]))
        #expect(empty.render(FlagMutation(threadIDs: ["t"], add: [], remove: [.inbox]))
                == LabelMutation(threadIDs: ["t"], add: [], remove: []))

        // A non-empty directory that simply lacks an archive is NOT refused: the
        // account can still move to trash, and refusing everything for a missing
        // folder would be its own silent-wrong-answer.
        let inboxOnly = IMAPMailboxDirectory(
            [IMAPMailbox(name: "INBOX", delimiter: "/", attributes: [], flag: .inbox,
                         isSpecialUseDeclared: false)])
        try runtime.store.saveIMAPMailboxDirectory(inboxOnly, accountID: "imap-1")
        let vocabulary = try #require(
            LabelVocabularyResolver.vocabulary(forAccountID: "imap-1", store: runtime.store))
        #expect(vocabulary.label(for: .inbox) == "INBOX")
        #expect(vocabulary.label(for: .archive) == nil)

        // And the kind-only overload is unchanged: it names no account, so it has
        // no directory and must keep refusing.
        #expect(LabelVocabularyResolver.vocabulary(for: .imap) == nil)
        runtime.teardown()
    }

    // MARK: - Sign-out

    @Test("signing out removes the settings, the mailbox list, the credential and the bookmark")
    func signOutPurgesEverythingIMAP() async throws {
        let (runtime, documents, secrets) = self.runtime()
        _ = Self.installOpener(on: runtime)
        let accountID = try await bounded("addIMAPAccount") {
            try await runtime.addIMAPAccount(address: "a@example.test",
                                             settings: self.settings(), password: "pw")
        }
        // The second, previously-uncovered purge gap: an `applemail-directory-<id>`
        // document that `DocumentMailStore.purge` did not remove. Written for the
        // SAME id so one sign-out has to clear both key families.
        documents.setData(Data("bookmark".utf8),
                          forKey: DocumentKeys.appleMailDirectory(accountID: accountID))
        try runtime.store.saveLabels([MailLabel(id: "l", name: "Folder A", kind: .user)],
                                     accountID: accountID)

        // A second account, to prove the purge is surgical rather than a wipe.
        let other = MailAccount(id: "gmail-1", provider: .gmail, address: "b@example.test",
                                displayName: "b", state: .ready)
        try runtime.store.saveAccount(other)
        secrets.setSecret("other-secret", forKey: IMAPAppPasswordStore.key(accountID: "gmail-1"))

        runtime.signOut(accountID)

        #expect(documents.storage[DocumentKeys.imapSettings(accountID: accountID)] == nil)
        #expect(documents.storage[DocumentKeys.imapMailboxes(accountID: accountID)] == nil)
        #expect(documents.storage[DocumentKeys.appleMailDirectory(accountID: accountID)] == nil)
        #expect(documents.storage[DocumentKeys.labels(accountID: accountID)] == nil)
        #expect(secrets.secret(forKey: IMAPAppPasswordStore.key(accountID: accountID)) == nil)
        #expect(runtime.accounts.map(\.id) == ["gmail-1"])
        // Untouched: the other account's secret. A `clear` that took no account id
        // would have removed this too.
        #expect(secrets.secret(forKey: IMAPAppPasswordStore.key(accountID: "gmail-1"))
                == "other-secret")
        runtime.teardown()
    }

    @Test("a store-level purge closes the same two gaps on its own")
    func storePurgeRemovesTheProviderDocuments() throws {
        let (runtime, documents, _) = self.runtime()
        let account = MailAccount(id: "imap-1", provider: .imap, address: "a@example.test",
                                  displayName: "a", state: .ready)
        try runtime.store.saveAccount(account)
        documents.setData(Data("{}".utf8), forKey: DocumentKeys.imapSettings(accountID: "imap-1"))
        documents.setData(Data("bm".utf8),
                          forKey: DocumentKeys.appleMailDirectory(accountID: "imap-1"))
        try runtime.store.saveIMAPMailboxDirectory(try IMAPProviderHarness.directory(),
                                                   accountID: "imap-1")

        // NOT `runtime.signOut` — the store alone, which is the path an MCP-driven
        // or store-level purge takes and which used to leave all three behind.
        try runtime.store.purge(accountID: "imap-1")

        #expect(documents.storage[DocumentKeys.imapSettings(accountID: "imap-1")] == nil)
        #expect(documents.storage[DocumentKeys.imapMailboxes(accountID: "imap-1")] == nil)
        #expect(documents.storage[DocumentKeys.appleMailDirectory(accountID: "imap-1")] == nil)
        runtime.teardown()
    }

    // MARK: - SMTP, which had no production caller

    @Test("an IMAP provider built from settings with an SMTP block can send; one without cannot")
    func smtpIsWiredFromTheStoredSettings() async throws {
        let (runtime, _, _) = self.runtime()
        _ = Self.installOpener(on: runtime)
        let accountID = try await bounded("addIMAPAccount") {
            try await runtime.addIMAPAccount(address: "a@example.test",
                                             settings: self.settings(), password: "pw")
        }

        let provider = try #require(runtime.providers.provider(for: accountID) as? IMAPProvider)
        #expect(provider.submit != nil)

        // The same factory, over settings with no submission server: the provider
        // is still built (reading still works) and only sending is refused.
        let account = MailAccount(id: accountID, provider: .imap, address: "a@example.test",
                                  displayName: "a", state: .ready)
        try runtime.providerFactory.saveIMAPAccount(settings: settings(withSMTP: false),
                                                    password: "pw", accountID: accountID)
        let noSMTP = try #require(
            try runtime.providerFactory.makeProvider(for: account) as? IMAPProvider)
        #expect(noSMTP.submit == nil)
        runtime.teardown()
    }

    @Test("send hands the message to the submitter exactly once and never retries")
    func sendIsAtMostOnce() async throws {
        let counter = SubmitCounter()
        let sending = IMAPProvider(accountID: "imap-1",
                                   submit: { _ in await counter.bump(); return "250 queued as Q1" },
                                   acquire: { throw MailTransportError.notConnected })
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.test")],
                                      subject: "Subject 1", bodyText: "Body 1")
        #expect(try await sending.send(message) == "250 queued as Q1")
        #expect(await counter.count == 1)

        // A failing submitter must throw straight through — no retry, no
        // second attempt, and above all no success inferred from the absence of one.
        let failing = IMAPProvider(accountID: "imap-1",
                                   submit: { _ in await counter.bump()
                                             throw MailError.sendOutcomeUnknown(message: "after DATA") },
                                   acquire: { throw MailTransportError.notConnected })
        await #expect(throws: MailError.sendOutcomeUnknown(message: "after DATA")) {
            try await failing.send(message)
        }
        #expect(await counter.count == 2)

        // And with no submitter at all, a refusal that names the missing half.
        let unsendable = IMAPProvider(accountID: "imap-1",
                                      acquire: { throw MailTransportError.notConnected })
        let error = await #expect(throws: MailError.self) { try await unsendable.send(message) }
        #expect("\(try #require(error))".contains("SMTP"))
    }

    actor SubmitCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }
}
