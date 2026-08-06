import Testing
import Foundation
@testable import RavenFeature

/// Task 13: the `MailProvider` conformance, asserted on recorded bytes.
///
/// Every await goes through `IMAPProviderHarness.expect`/`expectFailure`, which are
/// deadline-bounded. None may be called bare: an unanswered command presents as a
/// hang, a hung suite reports as an infrastructure timeout, and the bug is then
/// invisible. See `IMAPAuthHarness.boundedOutcome`.
///
/// Verified against fixtures and a scripted transport; **live verification is
/// deferred** — there is no IMAP app password in this milestone. What is
/// consequently unproven here is exactly `IMAPProvider.openSession` (connect,
/// authenticate, `LIST`) and `NetworkTransport`; everything above the transport seam
/// is exercised.
@Suite("IMAP provider")
struct IMAPProviderTests {

    private static let m1Thread = "imapt-88099c778cf88fc9"
    private static let m2Thread = "imapt-d6873810d2590c36"

    /// The three commands one `fetchThreads` page of INBOX issues, in order.
    private static let backfillSteps: [IMAPDeltaHarness.Step] = [
        .init("SELECT \"INBOX\"", "imap-provider-select"),
        .init("UID SEARCH SINCE", "imap-provider-search-linked"),
        .init("UID FETCH 20,11,10", "imap-provider-fetch-linked"),
    ]

    private static let since = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Conformance

    @Test("capabilities is readWrite")
    func capabilitiesAreReadWrite() async throws {
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [])
        #expect(provider.capabilities == .readWrite)
        #expect(provider.accountID == IMAPProviderHarness.accountID)
        await session.close()
    }

    // MARK: - Backfill

    @Test("a page walk selects a mailbox, searches by date, and threads what it fetched")
    func backfillWalksOneMailbox() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(
            steps: Self.backfillSteps)
        guard let page = await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) else { return }

        #expect(page.threads.map(\.id) == [Self.m1Thread])
        #expect(page.threads.first?.messages.count == 3)
        let wire = await transport.sentText
        // `SINCE` takes RFC 3501 `date-text`, not RFC 2822 and not INTERNALDATE's
        // form. A locale-dependent formatter would send `15-juin-2025`.
        #expect(wire.contains("UID SEARCH SINCE 15-Jun-2025"))
        // Newest first, and every UID of the page in ONE fetch.
        #expect(wire.contains("UID FETCH 20,11,10 (UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID REFERENCES IN-REPLY-TO)])"))
        // A `\Noselect` container is part of the hierarchy and can never be
        // SELECTed; doing so is a tagged NO that fails the whole walk.
        #expect(!wire.contains("SELECT \"Folder D\""))
        // The walk is not finished — the archive and trash mailboxes have not been
        // read — so the caller must be handed a token rather than `nil`, which it
        // would read as "backfill complete" and then seed the cursor from.
        #expect(page.nextPageToken == "1:")
        await session.close()
    }

    @Test("a mailbox with no matching UIDs advances to the next rather than fetching")
    func emptyMailboxIsSkipped() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select-empty"),
            .init("UID SEARCH SINCE", "imap-provider-search-none"),
            .init("SELECT \"Folder B\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-two"),
            .init("UID FETCH 11,10", "imap-provider-fetch-two-threads"),
        ])
        guard let page = await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) else { return }
        #expect(Set(page.threads.map(\.id)) == [Self.m1Thread, Self.m2Thread])
        let wire = await transport.sentText
        // An empty SEARCH must not be followed by a fetch of the empty set: `UID
        // FETCH  (…)` is a syntax error that fails the pass.
        #expect(!wire.contains("UID FETCH  "))
        #expect(page.nextPageToken == "2:")
        await session.close()
    }

    // MARK: - fetchThread

    @Test("a thread id the provider never walked is unknownThread, not an empty thread")
    func unknownThreadIsRefused() async throws {
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [])
        let error = await IMAPProviderHarness.expectFailure("fetchThread") {
            _ = try await provider.fetchThread(id: "imapt-0000000000000000")
        }
        #expect(error as? MailError == .unknownThread("imapt-0000000000000000"))
        await session.close()
    }

    @Test("a UIDVALIDITY change refuses the stale locators instead of fetching them")
    func staleGenerationIsRefused() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(
            steps: Self.backfillSteps + [
                .init("SELECT \"INBOX\"", "imap-provider-select-revalidated"),
            ])
        guard await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }
        let error = await IMAPProviderHarness.expectFailure("fetchThread") {
            _ = try await provider.fetchThread(id: Self.m1Thread)
        }
        #expect(error as? MailError == .unknownThread(Self.m1Thread))
        // The refusal happens BEFORE the fetch: UID 10 in generation 99 is somebody
        // else's message, so asking for it is the failure this guards.
        let wire = await transport.sentText
        #expect(wire.components(separatedBy: "UID FETCH 20,11,10").count == 2)
        await session.close()
    }

    // MARK: - Bodies and attachments

    @Test("a body is fetched on demand with BODY.PEEK, never BODY")
    func bodyIsFetchedWithPeek() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID FETCH 10 (BODYSTRUCTURE)", "imap-provider-body-structure"),
            .init("UID FETCH 10 (BODYSTRUCTURE BODY.PEEK[TEXT])", "imap-provider-body-text"),
        ])
        let locator = IMAPMessageLocator(mailbox: "INBOX", uidValidity: 7, uid: 10)
        guard let body = await IMAPProviderHarness.expect("fetchBody", {
            try await provider.fetchBody(messageID: locator.encoded)
        }) else { return }
        #expect(body.plainText == "Body 1")
        let wire = await transport.sentText
        // `BODY[…]` (no PEEK) sets `\Seen`. Opening a thread must not mark it read
        // behind the user's back.
        #expect(!wire.contains(" BODY[TEXT]"))
        #expect(wire.contains("BODY.PEEK[TEXT]"))
        await session.close()
    }

    @Test("fetchAttachment fetches one part, decodes it, and caches nothing")
    func attachmentIsFetchedOnDemandAndNotCached() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("BODY.PEEK[2]", "imap-provider-attachment"),
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("BODY.PEEK[2]", "imap-provider-attachment"),
        ])
        let locator = IMAPMessageLocator(mailbox: "INBOX", uidValidity: 7, uid: 10)
        guard let first = await IMAPProviderHarness.expect("fetchAttachment", {
            try await provider.fetchAttachment(messageID: locator.encoded, attachmentID: "2")
        }) else { return }
        // `QUJD` is base64 for `ABC`. Returning the base64 TEXT is the
        // plausible-but-wrong output: it is non-empty, printable, and would show up
        // as a corrupt file rather than as an error.
        #expect(first == Data("ABC".utf8))
        guard let second = await IMAPProviderHarness.expect("fetchAttachment again", {
            try await provider.fetchAttachment(messageID: locator.encoded, attachmentID: "2")
        }) else { return }
        #expect(second == first)
        let wire = await transport.sentText
        // TWO fetches for two calls: nothing was cached, on disk or in memory. A
        // cache would leave the user's attachments readable after sign-out, which
        // `DocumentMailStore.purge` cannot reach.
        #expect(wire.components(separatedBy: "BODY.PEEK[2]").count == 3)
        // Only part 2 was asked for — not the whole message.
        #expect(!wire.contains("BODY.PEEK[]"))
        #expect(!wire.contains("BODY.PEEK[1]"))
        await session.close()
    }

    // MARK: - Search

    @Test("searchThreads issues UID SEARCH and passes the query through untranslated")
    func searchDoesNotTranslateGmailGrammar() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"Folder B\"", "imap-provider-select"),
            .init("UID SEARCH TEXT", "imap-provider-search-two"),
            .init("UID FETCH 11,10", "imap-provider-fetch-two-threads"),
        ])
        guard let threads = await IMAPProviderHarness.expect("searchThreads", {
            try await provider.searchThreads(query: "from:a@example.test", limit: 10)
        }) else { return }
        #expect(Set(threads.map(\.id)) == [Self.m1Thread, Self.m2Thread])
        let wire = await transport.sentText
        // The query travels verbatim as a SEARCH TEXT argument. Translating
        // `from:` into IMAP's `FROM` key is exactly what `MailProvider.searchThreads`
        // declines to do, and a half-translation is worse than none.
        #expect(wire.contains("UID SEARCH TEXT \"from:a@example.test\""))
        #expect(!wire.contains("SEARCH FROM"))
        // Search is scoped to the account's all-mail/archive mailbox, so it reaches
        // beyond the inbox — the whole reason this path exists.
        #expect(wire.contains("SELECT \"Folder B\""))
        await session.close()
    }

    // MARK: - Labels

    @Test("fetchLabels reports the account's mailboxes, system only where canonical")
    func labelsComeFromTheMailboxList() async throws {
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [])
        guard let labels = await IMAPProviderHarness.expect("fetchLabels", {
            try await provider.fetchLabels()
        }) else { return }
        #expect(labels.map(\.id).sorted() == ["Folder B", "Folder C", "Folder D", "INBOX"])
        // The id is the mailbox name because that is what a mutation must round-trip
        // back to the server.
        #expect(labels.first { $0.id == "Folder B" }?.kind == .system)
        // A `\Noselect` container has no canonical meaning and must not be presented
        // as one of the server's own folders.
        #expect(labels.first { $0.id == "Folder D" }?.kind == .user)
        await session.close()
    }

    @Test("send names the missing SMTP half rather than silently succeeding")
    func sendIsRefusedUntilSMTPLands() async throws {
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [])
        let error = await IMAPProviderHarness.expectFailure("send") {
            try await provider.send(OutgoingMessage(
                to: [MailAddress(email: "a@example.test")],
                subject: "Subject 1", bodyText: "Body 1"))
        }
        #expect(error is MailError)
        await session.close()
    }
}
