import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// The two ways an IMAP account's *stored* description can go wrong after it was
/// written, both found by Task 16's gate.
///
/// Split from `IMAPAccountLifecycleTests` for the repo's line limit, along a real
/// seam: that file is about what one successful setup writes and one sign-out
/// removes, while every test here is about a document that is already on disk and
/// has since stopped matching reality — a TLS mode a later build wrote, and a
/// mailbox list the server has moved on from. Both strand or misroute an account
/// that was added perfectly.
@Suite("IMAP stored-settings drift")
@MainActor struct IMAPStoredSettingsDriftTests {

    /// Same shape as `IMAPAccountLifecycleTests.runtime()`: a torn-down runtime so
    /// the 120-second poll loop cannot race anything, plus the two in-memory stores.
    private func runtime() -> (RavenRuntime, InMemoryDocumentStore, InMemorySecretStore) {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        return (runtime,
                host.documents as! InMemoryDocumentStore,
                host.secrets as! InMemorySecretStore)
    }

    private func settings() -> IMAPAccountSettings {
        IMAPAccountSettings(host: "imap.example.test", port: 993, username: "a@example.test",
                            tls: .implicit,
                            smtp: SMTPAccountSettings(host: "smtp.example.test", port: 465,
                                                      tls: .implicit))
    }

    /// See `IMAPAccountLifecycleTests.bounded` — same two independent stops, same
    /// reason: the script turns a wrong expectation into an error, and this turns a
    /// never-resumed continuation into a failure.
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

    /// The account's mailboxes as they were when it was added: an archive, and no
    /// trash yet. The starting point for both drift tests below.
    private func directoryWithoutTrash() -> IMAPMailboxDirectory {
        IMAPMailboxDirectory([
            IMAPMailbox(name: "INBOX", delimiter: "/", attributes: [], flag: .inbox,
                        isSpecialUseDeclared: false),
            IMAPMailbox(name: "Folder B", delimiter: "/", attributes: ["\\Archive"],
                        flag: .archive, isSpecialUseDeclared: true),
        ])
    }

    // MARK: - Forward-compatible decoding (an unreadable value must not strand)

    @Test("an account whose settings name an unknown TLS mode is still buildable")
    func anUnknownTLSModeDoesNotStrandTheAccount() throws {
        let (runtime, documents, secrets) = self.runtime()
        let accountID = "imap-1"
        // Written by hand, as a later build would have written it. `makeProvider`
        // decodes with `try?`, so a throw in here does not surface as "bad TLS
        // mode" — it surfaces as "no settings document", and the account is listed
        // but permanently unconnectable with nothing saying why.
        documents.setData(Data((#"{"host":"imap.example.test","port":993,"#
                                + #""username":"u","tls":"requireTLS13"}"#).utf8),
                          forKey: DocumentKeys.imapSettings(accountID: accountID))
        secrets.setSecret("pw", forKey: IMAPAppPasswordStore.key(accountID: accountID))
        let account = MailAccount(id: accountID, provider: .imap, address: "a@example.test",
                                  displayName: "a", state: .ready)

        // The whole assertion: this does not throw.
        let provider = try #require(
            try runtime.providerFactory.makeProvider(for: account) as? IMAPProvider)
        #expect(provider.accountID == accountID)
        // No SMTP block in that document, so sending is refused by name while
        // reading keeps working — the refusal is scoped, not account-wide.
        #expect(provider.submit == nil)
        runtime.teardown()
    }

    // MARK: - The persisted directory must not drift from the live one

    /// The failure this task's review found, reproduced end to end: a Trash folder
    /// created after the account was added makes `trash` move mail to **Archive**.
    ///
    /// Nothing in the chain reports an error — the vocabulary drops the flag it
    /// cannot spell, the surviving `remove: ["INBOX"]` is byte-identical to an
    /// archive, and `applyLabels` resolves that against the live directory. This
    /// test pins the whole path on recorded wire bytes, so the wrong folder is
    /// observed rather than argued.
    @Test("a stale directory sends trash to the archive; a current one sends it to trash")
    func aStaleDirectoryMovesMailToTheWrongFolder() async throws {
        // Stale: what the server listed when the account was added. `Folder B` is
        // the archive; there is no trash yet.
        let stale = directoryWithoutTrash()
        let staleMutation = IMAPVocabulary(directory: stale)
            .render(ThreadAction.trash.mutation(threadIDs: [Self.m1Thread]))
        // The loss of intent, at the render step: "trash" has become indistinguishable
        // from "archive" before the provider ever sees it.
        #expect(staleMutation.add.isEmpty)
        #expect(staleMutation.remove == ["INBOX"])

        let wrong = try await Self.wire(applying: staleMutation)
        // `Folder C` is this account's real `\Trash`. The mail went to the archive.
        #expect(wrong.contains("UID MOVE 10,11,20 \"Folder B\""))
        #expect(!wrong.contains("Folder C"))

        // The same action, rendered from the directory the server actually has —
        // which is what `ProviderFactory.recordMailboxDirectory` keeps the persisted
        // copy equal to.
        let currentMutation = IMAPVocabulary(directory: try IMAPProviderHarness.directory())
            .render(ThreadAction.trash.mutation(threadIDs: [Self.m1Thread]))
        #expect(currentMutation.add == ["Folder C"])
        let right = try await Self.wire(applying: currentMutation)
        #expect(right.contains("UID MOVE 10,11,20 \"Folder C\""))
        #expect(!right.contains("Folder B"))
    }

    @Test("acquiring a session rewrites the persisted mailbox list, so trash stops meaning archive")
    func acquiringASessionRefreshesTheDirectory() async throws {
        let (runtime, _, _) = self.runtime()
        let spy = IMAPAccountLifecycleTests.installOpener(on: runtime)
        // The server as it was at account-add: no trash folder.
        spy.directory = directoryWithoutTrash()
        let accountID = try await bounded("addIMAPAccount") {
            try await runtime.addIMAPAccount(address: "a@example.test",
                                             settings: self.settings(), password: "pw")
        }
        // Before: the resolver cannot spell trash, which is the state that sends
        // mail to the archive.
        let before = try #require(
            LabelVocabularyResolver.vocabulary(forAccountID: accountID, store: runtime.store))
        #expect(before.label(for: .trash) == nil)

        // The user creates a Trash folder; the next session lists it.
        spy.directory = try IMAPProviderHarness.directory()
        let provider = try #require(runtime.providers.provider(for: accountID) as? IMAPProvider)
        // Any operation that acquires a session. This one finds no locators for a
        // thread the index has never seen and returns, so the only thing under test
        // is the acquire itself.
        try await bounded("acquire") {
            try await provider.applyLabels(
                LabelMutation(threadIDs: ["ghost"], add: ["\\Flagged"], remove: []))
        }

        // After: the persisted copy has been rewritten from the live LIST, and the
        // resolver now renders trash to the account's real trash mailbox.
        let after = try #require(
            LabelVocabularyResolver.vocabulary(forAccountID: accountID, store: runtime.store))
        #expect(after.label(for: .trash) == "Folder C")
        #expect(after.label(for: .archive) == "Folder B")
        runtime.teardown()
    }

    private static let m1Thread = "imapt-88099c778cf88fc9"

    private static let backfillSteps: [IMAPDeltaHarness.Step] = [
        .init("SELECT \"INBOX\"", "imap-provider-select"),
        .init("UID SEARCH SINCE", "imap-provider-search-linked"),
        .init("UID FETCH 20,11,10", "imap-provider-fetch-linked"),
    ]

    /// The bytes `applyLabels` puts on the wire for an already-rendered mutation,
    /// against the full fixture account (`Folder B` = archive, `Folder C` = trash).
    ///
    /// Takes a `LabelMutation` rather than a `ThreadAction` — unlike
    /// `IMAPProviderMutationTests.applying` — precisely because the point here is to
    /// vary the vocabulary the mutation was rendered with while holding the live
    /// directory fixed.
    private static func wire(applying mutation: LabelMutation) async throws -> String {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(
            capabilities: "IMAP4rev1 MOVE",
            steps: backfillSteps + [.init("SELECT \"INBOX\"", "imap-provider-select"),
                                    .init("UID MOVE")])
        _ = await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(
                since: Date(timeIntervalSince1970: 1_750_000_000), pageToken: nil)
        })
        _ = await IMAPProviderHarness.expect("applyLabels", {
            try await provider.applyLabels(mutation)
        })
        let wire = await transport.sentText
        await session.close()
        return wire
    }
}
