import Testing
import Foundation
@testable import RavenFeature

/// Task 8's command channel. Every test here runs over `ScriptedTransport` — no
/// socket and no server. **Live verification against a real IMAP server is
/// deferred:** there is no app password in M6, so what is proven here is the
/// channel's routing and teardown behaviour against recorded bytes.
///
/// The suite is deliberately hostile about *hangs*: every wait in
/// `Support/IMAPSessionHarness.swift` is deadline-bounded and fails the test
/// rather than spinning, because the failure mode this layer exists to prevent (a
/// waiter that never resumes) presents as a hang, and a hung run reports as an
/// infrastructure timeout instead of as a bug.
@Suite("IMAP command channel")
struct IMAPSessionTests {

    // MARK: - Greeting

    @Test("the greeting is parsed and its CAPABILITY code seeds the cache")
    func greetingParse() async throws {
        let transport = ScriptedTransport(idleReads: .suspend)
        await transport.enqueue(IMAPSessionHarness.greetingLine)
        let session = IMAPSession(transport: transport)
        let greeting = try await session.connect()
        #expect(greeting.kind == .ok)
        #expect(greeting.text == "[CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] ready")
        #expect(greeting.capabilities.contains("LOGINDISABLED"))
        #expect(await session.hasCapability("starttls"))
        // Seeded from the greeting: no CAPABILITY command needed.
        #expect(try await session.capabilities().contains("IMAP4REV1"))
        #expect(await transport.sent.isEmpty)
        await session.close()
    }

    @Test("a PREAUTH greeting is reported as such, and a BYE greeting throws")
    func greetingKinds() async throws {
        let preauthTransport = ScriptedTransport(idleReads: .suspend)
        await preauthTransport.enqueue("* PREAUTH IMAP4rev1 logged in\r\n")
        let preauth = IMAPSession(transport: preauthTransport)
        let greeting = try await preauth.connect()
        #expect(greeting.kind == .preauth)
        #expect(greeting.capabilities.isEmpty, "no [CAPABILITY] code means unknown, not empty")
        #expect(await preauth.cachedCapabilities == nil)
        await preauth.close()

        let transport = ScriptedTransport(idleReads: .suspend)
        await transport.enqueue("* BYE too many connections\r\n")
        let session = IMAPSession(transport: transport)
        await #expect(throws: IMAPSessionError.greetingRejected("too many connections")) {
            try await session.connect()
        }
        await session.close()
    }

    // MARK: - Pipelining

    @Test("two pipelined commands both resolve when the server answers out of order")
    func outOfOrderCompletion() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let first = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        let second = IMAPSessionHarness.issue(session, IMAPCommand("SELECT", [.text("Folder A")]))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 2))

        // Both commands are on the wire before either answer exists.
        let wire = await transport.sentText
        #expect(wire == "A0001 NOOP\r\nA0002 SELECT \"Folder A\"\r\n")

        // The SECOND command is answered first, in the same read.
        await transport.enqueue("A0002 OK select done\r\nA0001 OK noop done\r\n")

        let firstResponse = try #require(await IMAPSessionHarness.expectSuccess(first))
        let secondResponse = try #require(await IMAPSessionHarness.expectSuccess(second))
        #expect(firstResponse.tag == "A0001")
        #expect(firstResponse.text == "noop done")
        #expect(secondResponse.tag == "A0002")
        #expect(secondResponse.text == "select done")
        #expect(await session.inFlightCount == 0)
        await session.close()
    }

    @Test("out-of-order completions still resolve when responses are split mid-tag")
    func outOfOrderAcrossChunkBoundaries() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let first = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        let second = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 2))
        // One byte at a time: no read contains a whole line, let alone a whole tag.
        await transport.enqueue("A0002 OK second\r\nA0001 OK first\r\n", plan: .fixed(1))
        #expect(await IMAPSessionHarness.expectSuccess(first)?.text == "first")
        #expect(await IMAPSessionHarness.expectSuccess(second)?.text == "second")
        await session.close()
    }

    @Test("a NO resolves only its own waiter and leaves the other command running")
    func failureIsPerCommand() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let doomed = IMAPSessionHarness.issue(session, IMAPCommand("SELECT", [.text("Folder A")]))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        let survivor = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 2))

        await transport.enqueue("A0001 NO [NONEXISTENT] no such mailbox\r\n")
        await #expect(throws: IMAPSessionError.commandFailed(
            tag: "A0001", status: .no, text: "[NONEXISTENT] no such mailbox")) {
            try await doomed.value
        }
        // The other command is untouched: still in flight, still running.
        #expect(await session.inFlightCount == 1)
        #expect(await session.isRunning)
        await transport.enqueue("A0002 OK noop done\r\n")
        #expect(await IMAPSessionHarness.expectSuccess(survivor)?.status == .ok)
        await session.close()
    }

    @Test("a BAD completion is a typed error carrying its tag")
    func badCompletion() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        await transport.respond(to: "A0001 FROB", with: "A0001 BAD unknown command\r\n")
        await #expect(throws: IMAPSessionError.commandFailed(
            tag: "A0001", status: .bad, text: "unknown command")) {
            try await session.execute(IMAPCommand("FROB"))
        }
        #expect(await session.inFlightCount == 0)
        await session.close()
    }

    // MARK: - Untagged routing

    @Test("untagged responses arriving between an unrelated tag and its completion go to the sink")
    func untaggedNotMisattributed() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        var untagged: [IMAPUntaggedResponse] = []
        let collector = Task {
            var seen: [IMAPUntaggedResponse] = []
            for await response in session.untaggedResponses {
                seen.append(response)
                if seen.count == 2 { break }
            }
            return seen
        }

        let select = IMAPSessionHarness.issue(session, IMAPCommand("SELECT", [.text("Folder A")]))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        let noop = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 2))

        // Two untagged lines while BOTH commands are in flight, then the NOOP's
        // completion, then the SELECT's. Nothing here identifies an owner.
        await transport.enqueue("* 12 EXISTS\r\n* 3 RECENT\r\nA0002 OK noop done\r\n")
        let noopResponse = try #require(await IMAPSessionHarness.expectSuccess(noop))
        #expect(noopResponse.untagged.isEmpty,
                "untagged lines were attributed to a command that cannot be proven to own them")

        await transport.enqueue("A0001 OK [READ-WRITE] selected\r\n")
        let selectResponse = try #require(await IMAPSessionHarness.expectSuccess(select))
        #expect(selectResponse.untagged.isEmpty)

        untagged = await collector.value
        #expect(untagged.map(\.keyword) == ["EXISTS", "RECENT"])
        #expect(untagged.first?.tokens == [.number(12), .atom("EXISTS")])
        await session.close()
    }

    @Test("untagged responses are attributed when exactly one command is in flight")
    func untaggedAttributedWhenUnambiguous() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        await transport.respond(to: "A0001 FETCH",
                               with: "* 1 FETCH (UID 7)\r\nA0001 OK fetch done\r\n")
        let response = try await session.execute(
            IMAPCommand("FETCH", [.atom("1"), .list([.atom("UID")])]))
        #expect(response.untagged.count == 1)
        #expect(response.untagged.first?.keyword == "FETCH")
        await session.close()
    }

    // MARK: - Literals and continuations

    @Test("a synchronising literal waits for `+ ` before the payload is written")
    func synchronisingLiteral() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let payload = Data("Hello World".utf8)
        await transport.respond(to: "APPEND", with: "+ go ahead\r\n")
        await transport.respond(to: "Hello World", with: "A0001 OK appended\r\n")

        let response = try await session.execute(
            IMAPCommand("APPEND", [.text("Folder A"), .literal(payload)]))
        #expect(response.status == .ok)

        let writes = await transport.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(writes == ["A0001 APPEND \"Folder A\" {11}\r\n", "Hello World\r\n"],
                "the payload must be a separate write, sent only after the + request")
        #expect(await session.pendingContinuationTags.isEmpty)
        await session.close()
    }

    @Test("`{n+}` is used only when LITERAL+ is advertised")
    func nonSynchronisingLiteralRequiresCapability() async throws {
        // Same command, same session, before and after LITERAL+ appears.
        let (session, transport) = try await IMAPSessionHarness.makeSession(
            greeting: "* OK [CAPABILITY IMAP4rev1 LITERAL+] ready\r\n")
        #expect(await session.hasCapability("LITERAL+"))
        await transport.respond(to: "APPEND", with: "A0001 OK appended\r\n")
        try await session.execute(
            IMAPCommand("APPEND", [.text("Folder A"), .literal(Data("Hello World".utf8))]))
        let writes = await transport.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(writes == ["A0001 APPEND \"Folder A\" {11+}\r\nHello World\r\n"],
                "with LITERAL+ the whole command is one write and no + is awaited")
        await session.close()

        // And the plan itself: identical command, capability absent → {11}.
        let plan = IMAPCommand("APPEND", [.text("Folder A"), .literal(Data("Hello World".utf8))])
            .wirePlan(tag: "A0001", allowNonSynchronizingLiterals: false)
        #expect(plan.expectedContinuations == 1)
    }

    @Test("a continuation request nobody asked for tears the connection down")
    func unsolicitedContinuation() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let command = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        await transport.enqueue("+ why\r\n")
        await IMAPSessionHarness.expectAnyFailure(command)
        #expect(await session.inFlightCount == 0)
        #expect(await session.isRunning == false)
    }

    @Test("a completion for an unknown tag fails every waiter rather than being ignored")
    func unknownTag() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let command = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        await transport.enqueue("Z9999 OK who?\r\n")
        await IMAPSessionHarness.expectAnyFailure(command)
        #expect(await session.inFlightCount == 0)
    }

    // MARK: - Teardown

    @Test("closing the session mid-flight fails EVERY waiter and empties the in-flight table")
    func closeMidFlightFailsAllWaiters() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let commands = (0..<4).map { _ in IMAPSessionHarness.issue(session, IMAPCommand("NOOP")) }
        #expect(await IMAPSessionHarness.waitForInFlight(session, 4))
        await IMAPSessionHarness.waitForSuspendedRead(transport)

        await session.close()

        for command in commands {
            await IMAPSessionHarness.expectFailure(command, .closed)
        }
        #expect(await session.inFlightCount == 0,
                "a record left in the table is a leaked continuation")
        #expect(await session.pendingContinuationTags.isEmpty)
        #expect(await transport.isClosed)
        // And the session stays refusing rather than suspending.
        await #expect(throws: IMAPSessionError.notConnected) {
            try await session.execute(IMAPCommand("NOOP"))
        }
    }

    @Test("closing the TRANSPORT mid-flight fails every waiter through the read loop")
    func transportCloseMidFlightFailsAllWaiters() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let first = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        let second = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 2))
        await IMAPSessionHarness.waitForSuspendedRead(transport)

        // The peer hangs up: the read loop's suspended read throws, and the loop
        // must fail all waiters on its way out rather than merely stopping.
        await transport.close()

        await IMAPSessionHarness.expectFailure(first, .closed)
        await IMAPSessionHarness.expectFailure(second, .closed)
        #expect(await session.inFlightCount == 0)
        #expect(await session.isRunning == false)
        await session.close()
    }

    @Test("a mid-flight literal command is failed by close, leaving no pending continuation")
    func closeWhileAwaitingContinuation() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let command = IMAPSessionHarness.issue(session, IMAPCommand("APPEND",
                                                 [.text("Folder A"), .literal(Data("body".utf8))]))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        #expect(await session.pendingContinuationTags == ["A0001"])
        await IMAPSessionHarness.waitForSent(transport, 1)
        await session.close()
        await IMAPSessionHarness.expectFailure(command, .closed)
        #expect(await session.inFlightCount == 0)
        #expect(await session.pendingContinuationTags.isEmpty)
        // The payload was never written.
        #expect(await transport.sentText == "A0001 APPEND \"Folder A\" {4}\r\n")
    }

    @Test("malformed bytes fail every waiter instead of stalling the read loop")
    func malformedResponseFailsWaiters() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        let command = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        await transport.enqueue("A0001 OK done\n") // bare LF: illegal framing
        await IMAPSessionHarness.expectFailure(command, .malformedResponse(.malformedLineEnding))
        #expect(await session.inFlightCount == 0)
    }

    // MARK: - CAPABILITY lifecycle

    @Test("CAPABILITY is cached, and re-read after STARTTLS")
    func capabilityRereadAfterSTARTTLS() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        #expect(await session.hasCapability("LOGINDISABLED"))
        await transport.respond(to: "STARTTLS", with: "A0001 OK begin TLS\r\n")
        await transport.respond(
            to: "A0002 CAPABILITY",
            with: "* CAPABILITY IMAP4rev1 AUTH=PLAIN IDLE LITERAL+\r\nA0002 OK done\r\n")

        try await session.startTLS()

        #expect(await transport.startTLSCount == 1)
        // The pre-TLS list is discarded, not merged: LOGINDISABLED is gone.
        #expect(await session.hasCapability("LOGINDISABLED") == false)
        #expect(await session.hasCapability("IDLE"))
        #expect(await session.hasCapability("LITERAL+"))
        let wire = await transport.sentText
        #expect(wire == "A0001 STARTTLS\r\nA0002 CAPABILITY\r\n")

        // Cached now: a second read issues no command.
        _ = try await session.capabilities()
        #expect(await transport.sentText == wire)
        await session.close()
    }

    @Test("CAPABILITY is re-read after authentication even if one was already cached")
    func capabilityRereadAfterAuthentication() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession()
        await transport.respond(
            to: "A0001 CAPABILITY",
            with: "* CAPABILITY IMAP4rev1 IDLE MOVE\r\nA0001 OK done\r\n")
        let after = try await session.capabilitiesAfterAuthentication()
        #expect(after.contains("MOVE"))
        #expect(after.contains("LOGINDISABLED") == false)
        #expect(await transport.sentText == "A0001 CAPABILITY\r\n")
        await session.close()
    }

    @Test("a CAPABILITY carried only on the tagged OK is still learned")
    func capabilityFromTaggedOKOnly() async throws {
        let (session, transport) = try await IMAPSessionHarness.makeSession(greeting: "* OK ready\r\n")
        #expect(await session.cachedCapabilities == nil)
        await transport.respond(to: "CAPABILITY",
                               with: "A0001 OK [CAPABILITY IMAP4rev1 IDLE] done\r\n")
        let capabilities = try await session.capabilities()
        #expect(capabilities == ["IMAP4REV1", "IDLE"])
        await session.close()
    }

    // MARK: - Command rendering (pure)

    @Test("arguments are quoted, listed and literalised by the documented rules")
    func commandRendering() {
        let command = IMAPCommand("UID FETCH", [
            .atom("1:*"),
            .list([.atom("UID"), .atom("FLAGS")]),
            .quoted("a \"b\" \\c"),
        ])
        let plan = command.wirePlan(tag: "A0007", allowNonSynchronizingLiterals: false)
        #expect(plan.chunks.count == 1)
        #expect(String(decoding: plan.chunks[0], as: UTF8.self)
            == "A0007 UID FETCH 1:* (UID FLAGS) \"a \\\"b\\\" \\\\c\"\r\n")
    }

    @Test("Argument.text picks a literal exactly when a quoted string is illegal")
    func textArgumentChoosesLiteral() {
        #expect(IMAPCommand.Argument.text("Folder A") == .quoted("Folder A"))
        #expect(IMAPCommand.Argument.text("Ordner Ä") == .literal(Data("Ordner Ä".utf8)))
        #expect(IMAPCommand.Argument.text("a\r\nb") == .literal(Data("a\r\nb".utf8)))
    }

    @Test("a command's description never contains literal bytes")
    func descriptionRedactsLiterals() {
        let command = IMAPCommand("LOGIN", [.quoted("a@example.test"),
                                            .literal(Data("s3cret".utf8))])
        #expect(command.description == "LOGIN \"a@example.test\" {6 bytes}")
        #expect(command.description.contains("s3cret") == false)
    }
}
