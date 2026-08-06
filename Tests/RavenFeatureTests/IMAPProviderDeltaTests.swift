import Testing
import Foundation
@testable import RavenFeature

/// Task 13: `IMAPProvider.fetchDelta` — the per-mailbox walk, the union, and the two
/// places `changed.subtracting(removed)` bites.
///
/// Split from `IMAPProviderTests` for the repo's line limit, along the same seam
/// `IMAPAuthTests`/`IMAPAuthChannelTests` were: everything here is about what changed
/// since a cursor, everything there is a single-shot read.
///
/// Verified against fixtures and a scripted transport; live verification deferred.
@Suite("IMAP provider delta")
struct IMAPProviderDeltaTests {

    private static let m1Thread = "imapt-88099c778cf88fc9"
    private static let m2Thread = "imapt-d6873810d2590c36"
    private static let since = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Delta

    @Test("a thread that lost one message and gained another is removed, not also changed")
    func removalWinsOverChangeForOneThread() async throws {
        // The falsification of `changed.subtracting(removed)`, which no fixture in
        // Task 12 could make observable because thread ids were injected. Here they
        // are real: UID 10 (the thread's root) is expunged in the same pass as UID
        // 20 arrives citing it, so ONE thread id is both changed and removed.
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-two"),
            .init("UID FETCH 11,10", "imap-provider-fetch-two-threads"),
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID FETCH 20:*", "imap-provider-delta-expunge"),
            .init("UID FETCH 1:19", "imap-delta-plain-rescan"),
            .init("SELECT \"Folder B\"", "imap-provider-select-empty"),
            .init("SELECT \"Folder C\"", "imap-provider-select-empty"),
        ])
        guard await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }

        let seed = IMAPSyncCursor(mailboxes: [
            "INBOX": IMAPMailboxSyncState(uidValidity: 7, uidNext: 20),
        ])
        guard let delta = await IMAPProviderHarness.expect("fetchDelta", {
            try await provider.fetchDelta(cursor: seed.encoded())
        }) else { return }

        #expect(delta.removedThreadIDs == [Self.m1Thread])
        #expect(delta.changedThreadIDs.isEmpty)
        // The OTHER thread was neither changed nor removed: its flags matched the
        // re-scan, so a fallback that reported its whole re-scan as changed would
        // have named it.
        #expect(!delta.removedThreadIDs.contains(Self.m2Thread))
        #expect(!delta.changedThreadIDs.contains(Self.m2Thread))
        await session.close()
    }

    @Test("the delta strategy itself never reports one thread as both changed and removed")
    func strategySubtractsRemovedFromChanged() async throws {
        // The direct falsification of `IMAPDeltaStrategy`'s `changed.subtracting(
        // removed)`, which Task 12 could not make observable: its fixtures injected
        // thread ids, so no scripted mailbox could put ONE id on both sides. With real
        // ids it can — UID 10 is expunged in the same pass as UID 20 arrives citing
        // it — and this drives the strategy DIRECTLY rather than through
        // `IMAPProvider.fetchDelta`, which subtracts a second time and would mask the
        // strategy's omission.
        let (provider, _, backfill, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-two"),
            .init("UID FETCH 11,10", "imap-provider-fetch-two-threads"),
        ])
        guard await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }
        await backfill.close()

        let (session, _) = try await IMAPDeltaHarness.session(
            capabilities: "IMAP4rev1", steps: [
                .init("SELECT \"INBOX\"", "imap-provider-select"),
                .init("UID FETCH 20:*", "imap-provider-delta-expunge"),
                .init("UID FETCH 1:19", "imap-delta-plain-rescan"),
            ])
        let strategy = IMAPDeltaStrategy(
            session: session, identity: await provider.index.identity(for: "INBOX"))
        guard let result = await IMAPDeltaHarness.expectPass(strategy, from: IMAPSyncCursor(
            mailboxes: ["INBOX": IMAPMailboxSyncState(uidValidity: 7, uidNext: 20)]))
        else { return }
        #expect(result.delta.removedThreadIDs == [Self.m1Thread])
        #expect(result.delta.changedThreadIDs.isEmpty)
        await session.close()
    }

    @Test("a thread expunged in one folder and changed in another is removed, not also changed")
    func removalWinsAcrossMailboxes() async throws {
        // The falsification of the PROVIDER's `changed.subtracting(removed)`, which is
        // a different line from the strategy's and is not reachable by any single-
        // mailbox fixture. `IMAPDeltaStrategy` subtracts within one mailbox; this
        // collision only exists after the per-mailbox results are unioned, so it needs
        // one thread living in TWO folders.
        //
        // The same `Message-ID` appears at INBOX UID 10 and `Folder B` UID 30 — which
        // is ordinary on any server that files a copy rather than moving it — and
        // `IMAPThreadAssembler` collapses the duplicate onto one node, so both locators
        // belong to one thread id. The INBOX copy is then expunged in the same pass in
        // which the `Folder B` copy gains `\Flagged`: changed comes from one mailbox,
        // removed from the other, and only the provider-level subtraction can see both.
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-10"),
            .init("UID FETCH 10 ", "imap-provider-fetch-m1-only"),
            .init("SELECT \"Folder B\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-30"),
            .init("UID FETCH 30 ", "imap-provider-fetch-inbox-copy"),
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID FETCH 20:*", "imap-provider-delta-expunge-only"),
            .init("UID FETCH 1:19"),
            .init("SELECT \"Folder B\"", "imap-provider-select"),
            .init("UID FETCH 1:39", "imap-provider-rescan-30-changed"),
            .init("SELECT \"Folder C\"", "imap-provider-select-empty"),
        ])
        guard let page = await IMAPProviderHarness.expect("page 1", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) else { return }
        #expect(page.threads.map(\.id) == [Self.m1Thread])
        guard await IMAPProviderHarness.expect("page 2", {
            try await provider.fetchThreads(since: Self.since, pageToken: "1:")
        }) != nil else { return }
        // One thread, two folders — the premise the rest of the test rests on, asserted
        // rather than assumed.
        let locators = await provider.index.locators(threadID: Self.m1Thread)
        #expect(locators.map(\.mailbox) == ["Folder B", "INBOX"])

        let seed = IMAPSyncCursor(mailboxes: [
            "INBOX": IMAPMailboxSyncState(uidValidity: 7, uidNext: 20),
            "Folder B": IMAPMailboxSyncState(uidValidity: 7, uidNext: 40),
        ])
        guard let delta = await IMAPProviderHarness.expect("fetchDelta", {
            try await provider.fetchDelta(cursor: seed.encoded())
        }) else { return }
        #expect(delta.removedThreadIDs == [Self.m1Thread])
        #expect(delta.changedThreadIDs.isEmpty)
        await session.close()
    }

    @Test("one mailbox's re-scan never reports another mailbox's messages as removed")
    func knownUIDsAreScopedToTheMailbox() async throws {
        // The precondition Task 12 could not test because it had no supplier of
        // `knownUIDs`. INBOX holds UIDs 10/11 and `Folder B` holds 30/31, and both
        // re-scan windows are `1:39`, so every UID of BOTH mailboxes is inside BOTH
        // ranges. With an account-wide `knownUIDs`, INBOX's re-scan — which mentions
        // only 10 and 11 — makes 30 and 31 "known, in range and absent", i.e.
        // deleted, and `Folder B`'s re-scan does the same to 10 and 11. Every thread
        // in the account would be reported removed on the first delta pass, with no
        // error anywhere.
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-two"),
            .init("UID FETCH 11,10", "imap-provider-fetch-two-threads"),
            .init("SELECT \"Folder B\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-folder-b"),
            .init("UID FETCH 31,30", "imap-provider-fetch-folder-b"),
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID FETCH 1:39", "imap-delta-plain-rescan"),
            .init("SELECT \"Folder B\"", "imap-provider-select"),
            .init("UID FETCH 1:39", "imap-provider-rescan-folder-b"),
            .init("SELECT \"Folder C\"", "imap-provider-select-empty"),
        ])
        guard await IMAPProviderHarness.expect("page 1", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }
        guard await IMAPProviderHarness.expect("page 2", {
            try await provider.fetchThreads(since: Self.since, pageToken: "1:")
        }) != nil else { return }

        let seed = IMAPSyncCursor(mailboxes: [
            "INBOX": IMAPMailboxSyncState(uidValidity: 7, uidNext: 40),
            "Folder B": IMAPMailboxSyncState(uidValidity: 7, uidNext: 40),
        ])
        guard let delta = await IMAPProviderHarness.expect("fetchDelta", {
            try await provider.fetchDelta(cursor: seed.encoded())
        }) else { return }
        #expect(delta.removedThreadIDs.isEmpty)
        #expect(delta.changedThreadIDs.isEmpty)
        await session.close()
    }

    @Test("an arrival citing a held thread joins it rather than starting a new one")
    func arrivalAttachesToTheExistingThread() async throws {
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID SEARCH SINCE", "imap-provider-search-two"),
            .init("UID FETCH 11,10", "imap-provider-fetch-two-threads"),
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID FETCH 20:*", "imap-provider-fetch-arrival"),
            .init("UID FETCH 1:19", "imap-delta-plain-rescan"),
            .init("SELECT \"Folder B\"", "imap-provider-select-empty"),
            .init("SELECT \"Folder C\"", "imap-provider-select-empty"),
        ])
        guard await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }
        let seed = IMAPSyncCursor(mailboxes: [
            "INBOX": IMAPMailboxSyncState(uidValidity: 7, uidNext: 20),
        ])
        guard let delta = await IMAPProviderHarness.expect("fetchDelta", {
            try await provider.fetchDelta(cursor: seed.encoded())
        }) else { return }

        #expect(delta.changedThreadIDs == [Self.m1Thread])
        #expect(delta.removedThreadIDs.isEmpty)
        // And the index agrees with what was reported. A lone arrival handed to the
        // assembler would be its own root and get its OWN id — the delta would then
        // name a thread whose newest message `fetchThread` could not find, which is
        // silently losing the reply.
        let locators = await provider.index.locators(threadID: Self.m1Thread)
        #expect(locators.map(\.uid) == [10, 20])
        await session.close()
    }

    @Test("the cursor a delta returns carries every walked mailbox's position")
    func deltaCursorCoversEveryMailbox() async throws {
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(steps: [
            .init("SELECT \"INBOX\"", "imap-provider-select"),
            .init("UID FETCH 1:*", "imap-provider-fetch-two-threads"),
            .init("SELECT \"Folder B\"", "imap-provider-select-empty"),
            .init("SELECT \"Folder C\"", "imap-provider-select-empty"),
        ])
        guard let delta = await IMAPProviderHarness.expect("fetchDelta", {
            try await provider.fetchDelta(cursor: "")
        }) else { return }
        let cursor = IMAPSyncCursor(encoded: delta.newCursor)
        // Per-mailbox positions, in the one string `MailAccount.syncCursor` already
        // is. A cursor holding only the last mailbox walked would re-walk the others
        // from UID 1 forever.
        #expect(cursor.mailboxes["INBOX"]?.uidValidity == 7)
        #expect(cursor.mailboxes["INBOX"]?.uidNext == 21)
        #expect(cursor.mailboxes["Folder B"]?.uidValidity == 8)
        #expect(cursor.mailboxes["Folder C"]?.uidValidity == 8)
        #expect(cursor.mailboxes["Folder D"] == nil)
        await session.close()
    }

}
