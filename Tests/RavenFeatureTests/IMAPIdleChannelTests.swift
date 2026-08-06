import Testing
import Foundation
@testable import RavenFeature

/// The two exceptions `IDLE` needs from the command channel, and the guard that
/// keeps each one from becoming a general licence:
///
/// - a `+ ` continuation request for an `IDLE` **is** the acknowledgement, and must
///   be absorbed rather than treated as the fatal desynchronisation it is for every
///   other command; and
/// - `DONE` is untagged and written minutes later, so it cannot go through
///   `execute` — `sendIdleDone()` is the one byte sequence that bypasses it, and it
///   refuses unless the sole in-flight command really does hold the channel open.
///
/// `IMAPCommand.holdsChannelOpen` is what makes both checkable instead of
/// conventional, so each test below is paired with the contrast case that would
/// pass if the flag were ignored. `IMAPSessionTests` and `IMAPAuthChannelTests` are
/// untouched by this file.
@Suite struct IMAPIdleChannelTests {

    // MARK: - sendIdleDone refuses when there is no IDLE

    /// Nothing in flight: a bare `DONE` would be an untagged write the server
    /// cannot attribute, so it is refused and no byte reaches the transport.
    @Test func sendIdleDoneRefusesWithNothingInFlight() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        await #expect(throws: IMAPSessionError.protocolError("DONE with no IDLE in flight")) {
            try await session.sendIdleDone()
        }
        #expect(await transport.sent.isEmpty)
        await session.close()
    }

    /// An ordinary EXCLUSIVE command in flight is not an `IDLE`. This is the
    /// assertion the flag exists for: "the sole in-flight command" alone would be
    /// satisfied here, and writing `DONE` into a `SELECT`'s stream is exactly the
    /// desynchronisation that has no recovery.
    @Test func sendIdleDoneRefusesForANonIdleExclusiveCommand() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let select = IMAPSessionHarness.issue(
            session, IMAPCommand("SELECT", [.text("INBOX")], isExclusive: true))
        guard await IMAPSessionHarness.waitForInFlight(session, 1) else { return }

        await #expect(throws: IMAPSessionError.protocolError("DONE with no IDLE in flight")) {
            try await session.sendIdleDone()
        }
        // The SELECT's own command line, and nothing after it.
        #expect(await transport.sent.count == 1)

        await session.close()
        await IMAPSessionHarness.expectFailure(select, .closed)
    }

    /// With an `IDLE` in flight, `DONE` is written bare, untagged and alone.
    @Test func sendIdleDoneWritesTheBareUntaggedLine() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let idle = IMAPSessionHarness.issue(
            session, IMAPCommand("IDLE", isExclusive: true, holdsChannelOpen: true))
        guard await IMAPSessionHarness.waitForInFlight(session, 1) else { return }

        try await session.sendIdleDone()
        let writes = await transport.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(writes == ["A0001 IDLE\r\n", "DONE\r\n"])

        await transport.enqueue("A0001 OK IDLE terminated\r\n")
        #expect(await IMAPSessionHarness.expectSuccess(idle) != nil)
        await session.close()
    }

    // MARK: - The `+ ` for an IDLE is the acknowledgement

    /// `+ idling` is absorbed: nothing is written in answer to it, the command stays
    /// in flight, and its tagged completion still resolves it normally.
    ///
    /// The success at the end is the load-bearing part. If the `+ ` were treated as
    /// an unownable continuation, `handleContinuationRequest` would throw and the
    /// read loop would tear the session down, so the command would FAIL rather than
    /// complete — which is what the contrast test below shows actually happens for
    /// any other command.
    @Test func aContinuationRequestForIdleIsAbsorbed() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let idle = IMAPSessionHarness.issue(
            session, IMAPCommand("IDLE", isExclusive: true, holdsChannelOpen: true))
        guard await IMAPSessionHarness.waitForInFlight(session, 1) else { return }

        await transport.enqueue("+ idling\r\n")
        // Then an arrival and the completion, in one blob: if the `+ ` had torn the
        // session down neither would ever be parsed.
        await transport.enqueue("* 4 EXISTS\r\nA0001 OK IDLE terminated\r\n")
        let response = await IMAPSessionHarness.expectSuccess(idle)
        #expect(response?.untagged.first?.keyword == "EXISTS")
        // Nothing was written in reply to the `+ `.
        #expect(await transport.sent.count == 1)
        #expect(await session.isRunning)
        await session.close()
    }

    /// The contrast: the SAME shape without `holdsChannelOpen` is a continuation
    /// nobody can answer, and it tears the connection down. Without this, the test
    /// above would pass for a session that absorbs every stray `+ `.
    @Test func aContinuationRequestForAnOrdinaryCommandIsFatal() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let select = IMAPSessionHarness.issue(
            session, IMAPCommand("SELECT", [.text("INBOX")], isExclusive: true))
        guard await IMAPSessionHarness.waitForInFlight(session, 1) else { return }

        await transport.enqueue("+ go ahead\r\n")
        await IMAPSessionHarness.expectAnyFailure(select)
        #expect(await session.isRunning == false)
        #expect(await session.inFlightCount == 0)
    }

    // MARK: - Exclusivity, which is what makes DONE unjumpable

    /// While an `IDLE` is in flight nothing else may be issued on that session — so
    /// "DONE before any other command" is enforced by the channel rather than by
    /// the watcher remembering to do it in the right order.
    @Test func noCommandCanBeIssuedWhileIdleHoldsTheChannel() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let idle = IMAPSessionHarness.issue(
            session, IMAPCommand("IDLE", isExclusive: true, holdsChannelOpen: true))
        guard await IMAPSessionHarness.waitForInFlight(session, 1) else { return }

        await #expect(throws: IMAPSessionError.channelReserved(exclusiveTag: "A0001")) {
            try await session.execute(IMAPCommand("NOOP"))
        }
        await #expect(throws: IMAPSessionError.channelReserved(exclusiveTag: nil)) {
            try await session.execute(IMAPCommand("SELECT", [.text("INBOX")],
                                                 isExclusive: true))
        }
        // Neither refusal reached the wire.
        #expect(await transport.sent.count == 1)

        try await session.sendIdleDone()
        await transport.enqueue("A0001 OK IDLE terminated\r\n")
        #expect(await IMAPSessionHarness.expectSuccess(idle) != nil)
        await session.close()
    }

    // MARK: - IDLE runs on its own session

    /// A user action taken while the watcher is idling runs on a DIFFERENT session
    /// and completes without waiting for a `DONE`.
    ///
    /// Both halves are asserted, because either alone is weak: the action completing
    /// inside the deadline is what "never blocked" means, and the idling session
    /// having written no `DONE` at that point is what proves the action did not
    /// silently end the IDLE to get its turn. The refusal at the end shows why a
    /// second session is necessary rather than merely tidy — the same command on the
    /// idling session cannot run at all.
    @Test func aUserActionRunsOnItsOwnSessionAndNeverWaitsForDone() async throws {
        let clock = IMAPIdleHarness.FakeClock()
        let server = IMAPIdleHarness.Server(scripts: [
            IMAPIdleHarness.Script(),
            IMAPIdleHarness.Script(selectFixture: nil, doneCycles: 0,
                                   extra: [.init("NOOP", "%TAG% OK noop\r\n")]),
        ])
        let provider = IMAPIdleHarness.provider(server)
        let watcher = IMAPIdleWatcher(provider: provider, clock: clock, onNotification: {})
        let (task, box) = IMAPIdleHarness.start(watcher)
        defer { task.cancel() }
        guard await IMAPIdleHarness.waitUntilIdling(server, clock) else { return }

        let response = await IMAPProviderHarness.expect("a NOOP beside the IDLE") {
            try await provider.withSession { working in
                try await working.session.execute(IMAPCommand("NOOP"))
            }
        }
        #expect(response?.status == .ok)
        #expect(await server.connectionCount == 2)
        #expect(await IMAPIdleHarness.wire(server, 1) == "A0001 NOOP\r\n")
        // The idling session was not disturbed to make room for it.
        #expect(await IMAPIdleHarness.wire(server, 0).contains("DONE") == false)
        #expect(await watcher.cycleCount == 0)

        // And it could not have shared the idling session even if it tried.
        guard let idling = await server.connection(0) else { return }
        await #expect(throws: IMAPSessionError.channelReserved(exclusiveTag: "A0002")) {
            try await idling.session.execute(IMAPCommand("NOOP"))
        }

        await watcher.stop()
        #expect(await IMAPIdleHarness.outcome(box) == .stopped)
    }
}
