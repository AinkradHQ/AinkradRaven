import Testing
import Foundation
@testable import RavenFeature

/// Task 12: the two delta walks, and the assertion that they agree.
///
/// Every await goes through `IMAPDeltaHarness.pass`/`expectPass`, which are
/// deadline-bounded. None may be called bare — see `IMAPAuthHarness`'s note on
/// why a hang is worse than a failure.
@Suite("IMAP delta strategy")
struct IMAPDeltaStrategyTests {

    private static let condstore = "IMAP4rev1 CONDSTORE QRESYNC"
    /// The dangerous middle of the capability matrix: `CHANGEDSINCE` is available
    /// but `VANISHED` is not, because `QRESYNC` may not be sent.
    private static let condstoreOnly = "IMAP4rev1 CONDSTORE"
    private static let plain = "IMAP4rev1"

    private static let condstoreSteps: [IMAPDeltaHarness.Step] = [
        .init("SELECT", "imap-delta-condstore-select"),
        .init("CHANGEDSINCE 100", "imap-delta-condstore-changed"),
        .init("UID FETCH 20:*", "imap-delta-plain-arrivals"),
    ]

    /// CONDSTORE without QRESYNC: no `VANISHED` can arrive, so the removal comes
    /// from the same bounded set-difference re-scan the fallback uses.
    private static let condstoreOnlySteps: [IMAPDeltaHarness.Step] = [
        .init("SELECT", "imap-delta-condstore-only-select"),
        .init("CHANGEDSINCE 100", "imap-delta-condstore-changed"),
        .init("UID FETCH 20:*", "imap-delta-plain-arrivals"),
        .init("UID FETCH 1:19 (UID FLAGS)", "imap-delta-plain-rescan"),
    ]

    private static let fallbackSteps: [IMAPDeltaHarness.Step] = [
        .init("SELECT", "imap-delta-plain-select"),
        .init("UID FETCH 20:*", "imap-delta-plain-arrivals"),
        .init("UID FETCH 1:19", "imap-delta-plain-rescan"),
    ]

    private static func strategy(_ session: IMAPSession,
                                 window: UInt32 = 5_000) -> IMAPDeltaStrategy {
        IMAPDeltaStrategy(session: session, identity: IMAPDeltaHarness.identity(),
                          flagRescanWindow: window)
    }

    // MARK: - CONDSTORE advertised

    @Test("CONDSTORE resynchronises with QRESYNC and CHANGEDSINCE, and stores the new HIGHESTMODSEQ")
    func condstorePathUsesQresyncAndStoresModSeq() async throws {
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstore, steps: Self.condstoreSteps)
        guard let result = await IMAPDeltaHarness.expectPass(
            Self.strategy(session), from: IMAPDeltaHarness.storedCursor()) else { return }

        let wire = await transport.sentText
        #expect(wire.contains("SELECT \"Folder A\" (QRESYNC (1 100))"))
        #expect(wire.contains("(CHANGEDSINCE 100)"))
        // The change scan is cheap and bounded above by the arrival point: flags
        // and modseq only, and never the tail it does not own.
        #expect(wire.contains("UID FETCH 1:19 (UID FLAGS MODSEQ) (CHANGEDSINCE 100)"))
        #expect(!wire.contains("UID FETCH 1:* "))
        let state = try #require(result.cursor.mailboxes[IMAPDeltaHarness.mailbox])
        #expect(state.highestModSeq == 102)
        #expect(state.uidNext == 21)
        #expect(state.uidValidity == 1)
        await session.close()
    }

    @Test("VANISHED (EARLIER) becomes removedThreadIDs")
    func vanishedEarlierIsARemoval() async throws {
        let (session, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstore, steps: Self.condstoreSteps)
        guard let result = await IMAPDeltaHarness.expectPass(
            Self.strategy(session), from: IMAPDeltaHarness.storedCursor()) else { return }
        #expect(result.delta.removedThreadIDs == ["t-c"])
        // The removed thread must not also be reported as changed; a delta that
        // says both leaves the store's outcome dependent on apply order.
        #expect(result.delta.changedThreadIDs == ["t-a", "t-d"])
        await session.close()
    }

    @Test("an untagged EXPUNGE becomes removedThreadIDs too")
    func expungeIsARemoval() async throws {
        // No QRESYNC: the server reports the deletion as a sequence-numbered
        // EXPUNGE, which is what every non-QRESYNC server sends.
        let (session, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.plain,
            steps: [
                .init("SELECT", "imap-delta-plain-select"),
                // Sequence number 2, which the client's sequence map says is UID 11.
                .init("UID FETCH 20:*", "imap-delta-expunge"),
                .init("UID FETCH 1:19", "imap-delta-plain-rescan"),
            ])
        let strategy = IMAPDeltaStrategy(
            session: session,
            identity: IMAPDeltaHarness.identity(sequenceNumbers: [2: 11]))
        guard let result = await IMAPDeltaHarness.expectPass(
            strategy, from: IMAPDeltaHarness.storedCursor(highestModSeq: nil)) else { return }
        // t-b (UID 11) expunged, t-c (UID 12) still detected as absent from the
        // re-scan. Both mechanisms are live in the same pass.
        #expect(result.delta.removedThreadIDs == ["t-b", "t-c"])
        // UID 11's flag line is in the re-scan fixture, so an implementation that
        // ignored the EXPUNGE would report t-b as unchanged and nothing else —
        // it must not appear as changed here.
        #expect(result.delta.changedThreadIDs == ["t-a", "t-d"])
        await session.close()
    }

    // MARK: - CONDSTORE without QRESYNC

    @Test("CONDSTORE without QRESYNC still reports a message deleted between sessions")
    func condstoreOnlyDetectsRemovals() async throws {
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstoreOnly, steps: Self.condstoreOnlySteps)
        guard let result = await IMAPDeltaHarness.expectPass(
            Self.strategy(session), from: IMAPDeltaHarness.storedCursor()) else { return }

        let wire = await transport.sentText
        // QRESYNC was not advertised, so it must not be sent — and therefore no
        // `VANISHED` can ever arrive on this connection.
        #expect(!wire.contains("QRESYNC"))
        #expect(wire.contains("(CHANGEDSINCE 100)"))
        // Which is exactly why the set-difference re-scan must still run. Without
        // it UID 12's deletion is invisible, the cursor advances past it, and no
        // later pass ever looks below the new position again.
        #expect(wire.contains("UID FETCH 1:19 (UID FLAGS)"))
        #expect(result.delta.removedThreadIDs == ["t-c"])
        #expect(result.delta.changedThreadIDs == ["t-a", "t-d"])
        await session.close()
    }

    @Test("a flag-only CONDSTORE pass fetches no envelope, body structure or headers")
    func flagOnlyPassIsCheap() async throws {
        // The server's own UIDNEXT equals the stored one: nothing arrived, so the
        // expensive item list has nothing to describe.
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstore,
            steps: [
                .init("SELECT", "imap-delta-condstore-noarrivals-select"),
                .init("CHANGEDSINCE 100", "imap-delta-condstore-changed"),
                // Scripted but never expected to be reached. It is here so an
                // implementation that DOES issue the arrival fetch fails on the
                // wire assertions below rather than on the deadline — a hang and a
                // cost regression are different diagnoses.
                .init("UID FETCH 20:*", nil),
            ])
        guard let result = await IMAPDeltaHarness.expectPass(
            Self.strategy(session), from: IMAPDeltaHarness.storedCursor()) else { return }

        let wire = await transport.sentText
        // The cost assertion, pinned on the wire rather than argued in a comment:
        // a flag change across a large mailbox must not drag an envelope and a
        // header block per message down a timer tick.
        #expect(!wire.contains("BODYSTRUCTURE"))
        #expect(!wire.contains("ENVELOPE"))
        #expect(!wire.contains("BODY.PEEK"))
        // And the arrival fetch is skipped entirely, not merely made cheap.
        #expect(!wire.contains("UID FETCH 20:*"))
        #expect(result.delta.changedThreadIDs == ["t-a"])
        await session.close()
    }

    // MARK: - The fallback

    @Test("without CONDSTORE the fallback walks arrivals plus a bounded flag re-scan")
    func fallbackWalksArrivalsAndRescan() async throws {
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: Self.plain, steps: Self.fallbackSteps)
        guard let result = await IMAPDeltaHarness.expectPass(
            Self.strategy(session),
            from: IMAPDeltaHarness.storedCursor(highestModSeq: nil)) else { return }

        let wire = await transport.sentText
        #expect(wire.contains("UID FETCH 20:*"))
        #expect(wire.contains("UID FETCH 1:19 (UID FLAGS)"))
        // No CONDSTORE means no modifier may be sent: `CHANGEDSINCE` against a
        // server that never advertised it is a protocol violation.
        #expect(!wire.contains("CHANGEDSINCE"))
        #expect(!wire.contains("QRESYNC"))
        #expect(result.cursor.mailboxes[IMAPDeltaHarness.mailbox]?.highestModSeq == nil)
        await session.close()
    }

    @Test("the flag re-scan is bounded by flagRescanWindow, not by mailbox size")
    func rescanIsBoundedByTheWindow() async throws {
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: Self.plain,
            steps: [
                .init("SELECT", "imap-delta-plain-select"),
                .init("UID FETCH 20:*", "imap-delta-plain-arrivals"),
                // The window is 5, so the re-scan covers 15:19 and NOT 1:19.
                .init("UID FETCH 15:19", "imap-delta-plain-rescan"),
            ])
        guard await IMAPDeltaHarness.expectPass(
            Self.strategy(session, window: 5),
            from: IMAPDeltaHarness.storedCursor(highestModSeq: nil)) != nil else { return }
        let wire = await transport.sentText
        #expect(wire.contains("UID FETCH 15:19 (UID FLAGS)"))
        #expect(!wire.contains("UID FETCH 1:19"))
        await session.close()
    }

    @Test("a re-scan that returns an unchanged message does not report it as changed")
    func unchangedFlagsAreNotAChange() async throws {
        let (session, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.plain, steps: Self.fallbackSteps)
        guard let result = await IMAPDeltaHarness.expectPass(
            Self.strategy(session),
            from: IMAPDeltaHarness.storedCursor(highestModSeq: nil)) else { return }
        // UID 11 is in the re-scan with exactly its stored flags. Reporting the
        // whole re-scan as changed is the obvious wrong implementation and would
        // put "t-b" here on every single tick.
        #expect(!result.delta.changedThreadIDs.contains("t-b"))
        await session.close()
    }

    // MARK: - The equality that matters

    @Test("all three capability shapes produce the same delta for one mailbox")
    func allPathsAgree() async throws {
        let (fastSession, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstore, steps: Self.condstoreSteps)
        guard let fast = await IMAPDeltaHarness.expectPass(
            Self.strategy(fastSession), from: IMAPDeltaHarness.storedCursor()) else { return }
        await fastSession.close()

        // The middle of the matrix, and the one that was missing: CONDSTORE with
        // no QRESYNC. It is the most dangerous case precisely because it looks like
        // the fast path and cannot receive a `VANISHED`.
        let (middleSession, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstoreOnly, steps: Self.condstoreOnlySteps)
        guard let middle = await IMAPDeltaHarness.expectPass(
            Self.strategy(middleSession), from: IMAPDeltaHarness.storedCursor()) else { return }
        await middleSession.close()

        let (slowSession, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.plain, steps: Self.fallbackSteps)
        guard let slow = await IMAPDeltaHarness.expectPass(
            Self.strategy(slowSession),
            from: IMAPDeltaHarness.storedCursor(highestModSeq: nil)) else { return }
        await slowSession.close()

        // The expected value is written out here rather than computed by calling
        // any path: an assertion whose expectation comes from the code under test
        // proves only that the code equals itself.
        #expect(fast.delta.changedThreadIDs == ["t-a", "t-d"])
        #expect(fast.delta.removedThreadIDs == ["t-c"])

        // The whole `MailDelta`, compared as a value, with the ONE field that
        // legitimately differs substituted. `newCursor` must differ: a CONDSTORE
        // server hands back a HIGHESTMODSEQ and a server without the extension
        // cannot, so requiring byte-identical cursors would be requiring the fast
        // path to throw its own optimisation away. Every changed id, every removed
        // id and their order must be identical — which is what is pinned, and it
        // is deliberately not a claim that "everything else" agrees: a MODSEQ bump
        // with unchanged flags still diverges (the CONDSTORE paths report it, the
        // fallback's `knownFlags` comparison does not). That divergence is a
        // superset rather than a loss — the fast path reports a change the slow
        // path cannot see, never the reverse — and `walkChangedSince` is where it
        // is explained.
        for other in [middle.delta, slow.delta] {
            #expect(MailDelta(changedThreadIDs: fast.delta.changedThreadIDs,
                              removedThreadIDs: fast.delta.removedThreadIDs,
                              newCursor: other.newCursor) == other)
        }

        // And the cursor difference is exactly that one field, asserted rather
        // than assumed.
        let fastState = try #require(fast.cursor.mailboxes[IMAPDeltaHarness.mailbox])
        let middleState = try #require(middle.cursor.mailboxes[IMAPDeltaHarness.mailbox])
        let slowState = try #require(slow.cursor.mailboxes[IMAPDeltaHarness.mailbox])
        for state in [middleState, slowState] {
            #expect(fastState.uidValidity == state.uidValidity)
            #expect(fastState.uidNext == state.uidNext)
        }
        #expect(fastState.highestModSeq == 102)
        #expect(middleState.highestModSeq == 102)
        #expect(slowState.highestModSeq == nil)
    }

    // MARK: - Holding vs advancing

    @Test("a transient failure mid-delta holds the cursor")
    func transientFailureHoldsTheCursor() async throws {
        let before = IMAPDeltaHarness.storedCursor()
        let (session, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstore,
            steps: [
                .init("SELECT", "imap-delta-condstore-select"),
                // The SELECT succeeded and already carried a VANISHED and a new
                // HIGHESTMODSEQ. The fetch then fails: a delta pass that banked
                // the SELECT's position would lose every flag change above it,
                // permanently, since a cursor delta is never re-delivered.
                .init("CHANGEDSINCE 100", nil, status: "NO"),
            ])
        let strategy = Self.strategy(session)
        let box = IMAPDeltaHarness.CursorBox(before)
        let outcome = await boundedOutcome {
            try await box.run(strategy)
        }
        guard let outcome else { return }
        if case .success(let delta) = outcome {
            Issue.record("expected the pass to fail, got \(delta)")
        }
        let cursor = await box.cursor
        #expect(cursor == before)
        #expect(cursor.mailboxes[IMAPDeltaHarness.mailbox]?.highestModSeq == 100)
        #expect(cursor.mailboxes[IMAPDeltaHarness.mailbox]?.uidNext == 20)
        await session.close()
    }

    @Test("only a UIDVALIDITY change triggers a re-walk, and only for its own mailbox")
    func uidValidityChangeRewalksOneMailbox() async throws {
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: Self.condstore,
            steps: [
                // Same server, new generation. Note CONDSTORE is still advertised
                // and a HIGHESTMODSEQ is still reported — neither is what decides
                // the walk.
                .init("SELECT", "imap-delta-rewalk-select"),
                .init("UID FETCH 1:*", "imap-delta-plain-arrivals"),
            ])
        guard let result = await IMAPDeltaHarness.expectPass(
            Self.strategy(session), from: IMAPDeltaHarness.storedCursor()) else { return }

        let wire = await transport.sentText
        // A full walk from UID 1, NOT a CHANGEDSINCE against a modseq from a dead
        // generation, and no bounded re-scan below UID 1 either.
        #expect(wire.contains("UID FETCH 1:*"))
        #expect(!wire.contains("CHANGEDSINCE"))
        let state = try #require(result.cursor.mailboxes[IMAPDeltaHarness.mailbox])
        #expect(state.uidValidity == 7)
        #expect(state.uidNext == 21)
        // The sibling mailbox is untouched: one re-provisioned folder must not
        // cost an account-wide re-walk.
        #expect(result.cursor.mailboxes["Folder B"]
            == IMAPMailboxSyncState(uidValidity: 9, uidNext: 5, highestModSeq: 55))
        await session.close()
    }

    @Test("a SELECT with no UIDVALIDITY fails the pass rather than inventing a generation")
    func missingUIDValidityIsRefused() async throws {
        let (session, _) = try await IMAPDeltaHarness.session(
            capabilities: Self.plain,
            steps: [.init("SELECT", "imap-delta-no-uidvalidity-select")])
        guard let outcome = await IMAPDeltaHarness.pass(
            Self.strategy(session),
            from: IMAPDeltaHarness.storedCursor(highestModSeq: nil)) else { return }
        switch outcome {
        case .success(let result):
            Issue.record("expected a refusal, got \(result.delta)")
        case .failure(let error):
            #expect(error as? IMAPDeltaError
                == .missingUIDValidity(IMAPDeltaHarness.mailbox))
        }
        await session.close()
    }

    // MARK: - Refusing rather than guessing a folder

    @Test("a canonical flag with no mailbox is refused, not guessed")
    func missingMailboxIsRefused() throws {
        let directory = IMAPMailboxDirectory([
            IMAPMailbox(name: "INBOX", delimiter: "/", attributes: [],
                        flag: .inbox, isSpecialUseDeclared: false),
        ])
        #expect(throws: IMAPDeltaError.mailboxNotFound(.archive)) {
            try IMAPDeltaStrategy.mailboxName(for: .archive, in: directory)
        }
        #expect(try IMAPDeltaStrategy.mailboxName(for: .inbox, in: directory) == "INBOX")
    }
}
