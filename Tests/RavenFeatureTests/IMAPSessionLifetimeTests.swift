import Testing
import Foundation
@testable import RavenFeature

/// Task 13: every provider operation gives back the session it borrowed.
///
/// Its own suite because the defect it guards is invisible to every other suite by
/// construction: `IMAPProviderHarness.provider` hands back one shared scripted
/// session and each test closes it itself, so a provider that never released
/// anything would look identical in the recorded bytes and in every returned value.
/// The acquire/release balance is the only observable, which is why it is counted.
///
/// What the gate found, and what these pin: `openSession` connects, authenticates and
/// `LIST`s once per operation — per `fetchThreads` PAGE — and nothing called
/// `IMAPSession.close()` in production at all. The connection was reclaimed only when
/// the read loop hit its 60-second `readTimeout`, so a backfill paging N times inside
/// a minute held N authenticated connections against a per-user cap servers commonly
/// set at 10–20, and the cap surfaces as a connect failure on a later, unrelated
/// operation.
@Suite("IMAP session lifetime", .timeLimit(.minutes(1)))
struct IMAPSessionLifetimeTests {

    private static let since = Date(timeIntervalSince1970: 1_750_000_000)
    private static let m1Thread = "imapt-88099c778cf88fc9"

    private static let backfillSteps: [IMAPDeltaHarness.Step] = [
        .init("SELECT \"INBOX\"", "imap-provider-select"),
        .init("UID SEARCH SINCE", "imap-provider-search-linked"),
        .init("UID FETCH 20,11,10", "imap-provider-fetch-linked"),
    ]

    @Test("each read operation releases the session it borrowed")
    func readOperationsBalanceTheirLeases() async throws {
        let (provider, _, session, leases) = try await IMAPProviderHarness.provider(steps:
            Self.backfillSteps + [
                .init("SELECT \"INBOX\"", "imap-provider-select"),
                .init("UID FETCH 10 (BODYSTRUCTURE)", "imap-provider-body-structure"),
                .init("UID FETCH 10 (BODYSTRUCTURE BODY.PEEK[TEXT])", "imap-provider-body-text"),
            ])
        guard await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }
        guard await IMAPProviderHarness.expect("fetchLabels", {
            try await provider.fetchLabels()
        }) != nil else { return }
        let locator = IMAPMessageLocator(mailbox: "INBOX", uidValidity: 7, uid: 10)
        guard await IMAPProviderHarness.expect("fetchBody", {
            try await provider.fetchBody(messageID: locator.encoded)
        }) != nil else { return }

        // Three operations, three acquires, three releases. The count — not merely
        // the balance — matters: a provider that acquired once and cached would show
        // 1/1 and still be the shape the gate objected to for `fetchThreads` pages.
        #expect(await leases.acquired == 3)
        #expect(await leases.released == 3)
        await session.close()
    }

    @Test("a page walk borrows exactly one session per page, and returns each")
    func everyBackfillPageReleasesItsSession() async throws {
        // The concrete leak the gate described: N pages inside one minute. Two pages
        // here, and each must give its connection back before the next asks for one.
        let (provider, _, session, leases) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-two"),
            .init("UID FETCH 11,10", "imap-provider-fetch-two-threads"),
            .init("SELECT \"Folder B\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-folder-b"),
            .init("UID FETCH 31,30", "imap-provider-fetch-folder-b"),
        ])
        guard let first = await IMAPProviderHarness.expect("page 1", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) else { return }
        #expect(await leases.released == 1)
        guard await IMAPProviderHarness.expect("page 2", {
            try await provider.fetchThreads(since: Self.since, pageToken: first.nextPageToken)
        }) != nil else { return }
        #expect(await leases.acquired == 2)
        #expect(await leases.released == 2)
        await session.close()
    }

    @Test("a mutation releases its session too")
    func applyLabelsReleasesItsLease() async throws {
        let (provider, _, session, leases) = try await IMAPProviderHarness.provider(
            capabilities: "IMAP4rev1 MOVE",
            steps: Self.backfillSteps + [
                .init("SELECT \"INBOX\"", "imap-provider-select"),
                .init("UID MOVE"),
            ])
        guard await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }
        let mutation = IMAPVocabulary(directory: try IMAPProviderHarness.directory())
            .render(ThreadAction.archive.mutation(threadIDs: [Self.m1Thread]))
        guard await IMAPProviderHarness.expect("applyLabels", {
            try await provider.applyLabels(mutation)
        }) != nil else { return }
        #expect(await leases.acquired == 2)
        #expect(await leases.released == 2)
        await session.close()
    }

    @Test("a FAILED operation releases its session as well")
    func failedOperationStillReleases() async throws {
        // The half that matters. `defer` cannot await, so the throwing path is written
        // out by hand in `withSession` and is exactly the line most likely to be
        // dropped by a later edit. An unreleased session after a FAILURE is worse than
        // after a success: a server that just refused a `SELECT` is often one that is
        // already at its connection limit, so the leak compounds the very condition
        // that caused it.
        let (provider, _, session, leases) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", status: "NO"),
        ])
        let error = await IMAPProviderHarness.expectFailure("fetchThreads") {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }
        #expect(error != nil)
        #expect(await leases.acquired == 1)
        #expect(await leases.released == 1)
        await session.close()
    }

    @Test("the production release sends LOGOUT and closes the connection")
    func productionReleaseLogsOutAndCloses() async throws {
        // Runs the REAL `IMAPProvider.closeSession` — the function `ProviderFactory`
        // binds into every production lease — rather than a test double of it, so what
        // is asserted here is what a live account does. `fetchLabels` is used because
        // it answers from the already-`LIST`ed directory and issues no commands of its
        // own, leaving `LOGOUT` as the only traffic.
        let (provider, transport, session, leases) = try await IMAPProviderHarness.provider(
            steps: [.init("LOGOUT")], closesOnRelease: true)
        guard let labels = await IMAPProviderHarness.expect("fetchLabels", {
            try await provider.fetchLabels()
        }) else { return }
        #expect(!labels.isEmpty)
        #expect(await leases.released == 1)

        let wire = await transport.sentText
        // `LOGOUT` before the socket goes, so the server frees the slot immediately
        // instead of waiting for its own idle timeout to notice.
        #expect(wire.contains("LOGOUT\r\n"))
        // And the connection really is gone — the assertion the whole finding is about.
        #expect(await transport.isClosed)
        #expect(await session.isRunning == false)
    }

    @Test("closeSession still closes the transport when LOGOUT is refused")
    func releaseClosesEvenWhenLogoutFails() async throws {
        // `LOGOUT` is best-effort; closing is not. A server that answers `BAD` — or
        // does not answer at all — must not be able to keep the socket open, because
        // the close is the part that returns the connection slot.
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: "IMAP4rev1", steps: [.init("LOGOUT", status: "BAD")])
        let working = IMAPWorkingSession(session: session,
                                        directory: try IMAPProviderHarness.directory())
        guard await IMAPProviderHarness.expect("closeSession", {
            await IMAPProvider.closeSession(working)
        }) != nil else { return }
        #expect(await transport.isClosed)
        #expect(await session.isRunning == false)
    }
}
