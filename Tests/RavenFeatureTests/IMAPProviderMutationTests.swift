import Testing
import Foundation
@testable import RavenFeature

/// Task 13: `applyLabels` — canonical flags to `UID STORE`, and folder changes to
/// `UID MOVE` or its three-command equivalent.
///
/// Split from `IMAPProviderTests` for the repo's line limit, the same way
/// `IMAPAuthTests`/`IMAPAuthChannelTests` were, and along the same seam: everything
/// here is a WRITE asserted on recorded bytes, everything there is a read.
///
/// Every mutation is built by `IMAPVocabulary.render` rather than hand-written, so
/// these assert the whole canonical-flag → wire path — which is what the acceptance
/// criterion asks for — rather than the provider's half of it against strings a test
/// author chose.
@Suite("IMAP provider mutations")
struct IMAPProviderMutationTests {

    private static let m1Thread = "imapt-88099c778cf88fc9"

    private static let backfillSteps: [IMAPDeltaHarness.Step] = [
        .init("SELECT \"INBOX\"", "imap-provider-select"),
        .init("UID SEARCH SINCE", "imap-provider-search-linked"),
        .init("UID FETCH 20,11,10", "imap-provider-fetch-linked"),
    ]

    private static let since = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - The flag branch

    @Test("marking read renders to UID STORE +FLAGS (\\Seen) — the \\Unseen inversion")
    func markReadStoresSeen() async throws {
        let wire = try await Self.applying(.setRead(true), steps: [.init("UID STORE")])
        #expect(wire.contains("UID STORE 10,11,20 +FLAGS.SILENT (\\Seen)"))
        // The inversion is the whole point: rendering `.unread` straight through
        // would send `-FLAGS (\Unseen)`, and the plausible wrong fix — treating
        // `remove: [.unread]` as `-FLAGS (\Seen)` — would mark the thread UNREAD.
        #expect(!wire.contains("-FLAGS"))
        #expect(!wire.contains("Unseen"))
    }

    @Test("marking unread renders to UID STORE -FLAGS (\\Seen)")
    func markUnreadClearsSeen() async throws {
        let wire = try await Self.applying(.setRead(false), steps: [.init("UID STORE")])
        #expect(wire.contains("UID STORE 10,11,20 -FLAGS.SILENT (\\Seen)"))
        #expect(!wire.contains("+FLAGS"))
    }

    @Test("starring renders to UID STORE +FLAGS (\\Flagged) and moves nothing")
    func starringStoresFlagged() async throws {
        let wire = try await Self.applying(.star(true), steps: [.init("UID STORE")])
        #expect(wire.contains("UID STORE 10,11,20 +FLAGS.SILENT (\\Flagged)"))
        // A star is not a folder change. A provider that routed every rendered
        // string through the move path would relocate the thread.
        #expect(!wire.contains("UID MOVE"))
        #expect(!wire.contains("UID COPY"))
    }

    // MARK: - The folder branch

    @Test("archive uses UID MOVE when MOVE is advertised, to the account's own archive name")
    func archiveUsesMoveWhenAdvertised() async throws {
        let wire = try await Self.applying(.archive, capabilities: "IMAP4rev1 MOVE",
                                          steps: [.init("UID MOVE")])
        // `Folder B` is this account's `\Archive`. A provider that guessed
        // `"Archive"` would send a mailbox that does not exist here.
        #expect(wire.contains("UID MOVE 10,11,20 \"Folder B\""))
        #expect(!wire.contains("UID COPY"))
        #expect(!wire.contains("EXPUNGE"))
    }

    @Test("archive falls back to COPY + STORE \\Deleted + EXPUNGE, in that order")
    func archiveFallsBackToCopyDeleteExpunge() async throws {
        let wire = try await Self.applying(.archive, capabilities: "IMAP4rev1", steps: [
            .init("UID COPY"), .init("UID STORE"), .init("EXPUNGE"),
        ])
        #expect(wire.contains("UID COPY 10,11,20 \"Folder B\""))
        #expect(wire.contains("UID STORE 10,11,20 +FLAGS.SILENT (\\Deleted)"))
        #expect(wire.contains("EXPUNGE\r\n"))
        // MOVE was not advertised, so sending it is a protocol violation.
        #expect(!wire.contains("UID MOVE"))
        // Order is correctness, not style: marking or expunging before the copy
        // succeeded is how a move loses mail.
        //
        // **What actually enforces it is the step ordering above, not the offset
        // comparisons below.** `IMAPDeltaHarness.session` answers step *n* with tag
        // `A000n`, so a reordered implementation gets a completion for a tag that is
        // not in flight: the session fails with `protocolError("completion for unknown
        // tag …")`, `applyLabels` throws, and the three `wire.contains` assertions
        // above fail. That is how the reorder mutant died — at the `applyLabels` call
        // and on the `UID COPY` byte assertion — and these offset checks never even
        // executed, because a `#require` earlier in the test had already failed.
        // Recorded plainly rather than left implied: crediting the wrong assertion is
        // how a test gets "simplified" into one that no longer catches anything. They
        // are kept as belt-and-braces, since they cost nothing and would catch a
        // reorder on a harness that matched needles without tags.
        let copy = try #require(wire.range(of: "UID COPY"))
        let deleted = try #require(wire.range(of: "\\Deleted"))
        let expunge = try #require(wire.range(of: "EXPUNGE\r\n"))
        #expect(copy.lowerBound < deleted.lowerBound)
        #expect(deleted.lowerBound < expunge.lowerBound)
    }

    @Test("trash moves to the trash mailbox, not to the archive")
    func trashPrefersTheAddedMailbox() async throws {
        let wire = try await Self.applying(.trash, capabilities: "IMAP4rev1 MOVE",
                                          steps: [.init("UID MOVE")])
        // `.trash` renders BOTH `add: [Folder C]` and `remove: [INBOX]`. The added
        // mailbox is the destination; falling through to the archive — the plausible
        // wrong rule, since a mailbox was also removed — would file a deletion into
        // the archive and the mail would never reach the trash.
        #expect(wire.contains("UID MOVE 10,11,20 \"Folder C\""))
        #expect(!wire.contains("\"Folder B\""))
    }

    @Test("an account with no archive mailbox refuses the archive rather than doing nothing")
    func archiveWithoutAnArchiveMailboxRefuses() async throws {
        // INBOX only: no `\Archive` anywhere.
        let directory = IMAPMailboxDirectory([
            IMAPMailbox(name: "INBOX", delimiter: "/", attributes: ["\\HasNoChildren"],
                        flag: .inbox, isSpecialUseDeclared: false),
        ])
        let (session, _) = try await IMAPDeltaHarness.session(
            capabilities: "IMAP4rev1 MOVE",
            steps: Self.backfillSteps + [.init("SELECT \"INBOX\"", "imap-provider-select")])
        let working = IMAPWorkingSession(session: session, directory: directory)
        let provider = IMAPProvider(accountID: IMAPProviderHarness.accountID) {
            IMAPSessionLease(working: working) {}
        }
        guard await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: Self.since, pageToken: nil)
        }) != nil else { return }

        let mutation = IMAPVocabulary(directory: directory)
            .render(ThreadAction.archive.mutation(threadIDs: [Self.m1Thread]))
        // Rendering already dropped the un-nameable flags, so the mutation reaching
        // the provider is `remove: ["INBOX"]` and nothing else.
        #expect(mutation.remove == ["INBOX"])
        let error = await IMAPProviderHarness.expectFailure("applyLabels") {
            try await provider.applyLabels(mutation)
        }
        // A silent success is the failure mode: `ThreadMutationApplier` has already
        // updated the local copy, so a no-op leaves the UI claiming the thread was
        // archived forever.
        #expect(error as? MailError
            == .providerFailed(status: -1, message: "no archive mailbox for this account"))
        await session.close()
    }

    /// Backfills, then applies `action` rendered through the account's vocabulary,
    /// and returns everything that reached the wire.
    private static func applying(_ action: ThreadAction,
                                 capabilities: String = "IMAP4rev1",
                                 steps: [IMAPDeltaHarness.Step]) async throws -> String {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(
            capabilities: capabilities,
            steps: backfillSteps + [.init("SELECT \"INBOX\"", "imap-provider-select")] + steps)
        _ = await IMAPProviderHarness.expect("fetchThreads", {
            try await provider.fetchThreads(since: since, pageToken: nil)
        })
        let mutation = IMAPVocabulary(directory: try IMAPProviderHarness.directory())
            .render(action.mutation(threadIDs: [m1Thread]))
        _ = await IMAPProviderHarness.expect("applyLabels", {
            try await provider.applyLabels(mutation)
        })
        // Returned even when the call failed, deliberately: an early `return ""`
        // makes every byte assertion below fail with "false", which says nothing
        // about what actually went on the wire. The recorded bytes are the only
        // diagnostic this test has.
        let wire = await transport.sentText
        await session.close()
        return wire
    }
}
