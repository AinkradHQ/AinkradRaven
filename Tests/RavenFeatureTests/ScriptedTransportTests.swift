import Foundation
import Testing
@testable import RavenFeature

/// Covers the scripted double itself. Everything above the transport seam is
/// tested through it, so if it lies — merges chunks, drops bytes, forgets the
/// TLS upgrade point — every later task's test is worthless.
@Suite("ScriptedTransport")
struct ScriptedTransportTests {

    /// A response with a `{n}` literal whose bytes contain CRLF, a quote, a
    /// paren and a brace: the exact payload a naive line splitter mangles.
    private static let literalResponse =
        "* 1 FETCH (BODY[] {23}\r\nline one\r\n\") { line two\r\n)\r\nA001 OK done\r\n"

    // MARK: - Chunking: the capability Task 7 depends on

    @Test("Every split point of a response reassembles byte-identically")
    func everySplitPointReassembles() async throws {
        let expected = Data(Self.literalResponse.utf8)
        for split in 0...expected.count {
            let transport = ScriptedTransport(chunkPlan: .splitAt(split))
            try await transport.connect()
            await transport.enqueue(Self.literalResponse)
            var received = Data()
            while await transport.unreadChunkCount > 0 {
                received.append(try await transport.read())
            }
            #expect(received == expected, "split at \(split) lost or reordered bytes")
        }
    }

    @Test("A split lands exactly where asked, including mid-CRLF and mid-literal")
    func splitLandsWhereAsked() async throws {
        let text = "A001 OK\r\n"
        // Mid-CRLF: offset 8 puts CR at the end of chunk 0 and LF alone in 1 —
        // the split a line-oriented parser is most likely to get wrong.
        let midCRLF = ScriptedTransport.chunks(of: Data(text.utf8), plan: .splitAt(8))
        #expect(midCRLF.count == 2)
        #expect(String(data: midCRLF[0], encoding: .utf8) == "A001 OK\r")
        #expect(String(data: midCRLF[1], encoding: .utf8) == "\n")

        // Mid-literal: the split falls inside the literal's own bytes.
        let literal = Data(Self.literalResponse.utf8)
        let insideLiteral = ScriptedTransport.chunks(of: literal, plan: .splitAt(30))
        #expect(insideLiteral.count == 2)
        #expect(insideLiteral[0].count == 30)
        #expect(insideLiteral[0] + insideLiteral[1] == literal)
    }

    @Test("Byte-at-a-time chunking yields one chunk per byte and no empty chunk")
    func byteAtATime() async throws {
        let transport = ScriptedTransport(chunkPlan: .fixed(1))
        try await transport.connect()
        await transport.enqueue(Self.literalResponse)
        let expected = Data(Self.literalResponse.utf8)
        #expect(await transport.unreadChunkCount == expected.count)
        var received = Data()
        for _ in 0..<expected.count {
            let chunk = try await transport.read()
            #expect(chunk.count == 1)
            received.append(chunk)
        }
        #expect(received == expected)
    }

    @Test("Explicit boundaries split at each offset, out-of-range ones ignored")
    func explicitBoundaries() async throws {
        let data = Data("0123456789".utf8)
        let chunks = ScriptedTransport.chunks(of: data, plan: .boundaries([7, 3, 0, 10, 99]))
        let texts = chunks.map { String(data: $0, encoding: .utf8) }
        #expect(texts == ["012", "3456", "789"])
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test("Whole-buffer and split delivery are indistinguishable once concatenated")
    func wholeMatchesSplit() async throws {
        let whole = ScriptedTransport.chunks(of: Data(Self.literalResponse.utf8), plan: .whole)
        #expect(whole.count == 1)
        let split = ScriptedTransport.chunks(of: Data(Self.literalResponse.utf8), plan: .fixed(4))
        #expect(split.reduce(into: Data()) { $0.append($1) } == whole[0])
    }

    // MARK: - Per-command answers: the capability Task 8 depends on

    @Test("Responses differ per received command, in rule order, consumed once")
    func answersPerCommand() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue("* OK greeting\r\n")
        await transport.respond(to: "CAPABILITY", with: "* CAPABILITY IMAP4rev1\r\nA1 OK\r\n")
        await transport.respond(to: "SELECT", with: "* 3 EXISTS\r\nA2 OK\r\n")
        try await transport.connect()

        #expect(String(data: try await transport.read(), encoding: .utf8) == "* OK greeting\r\n")

        try await transport.send(Data("A2 SELECT INBOX\r\n".utf8))
        #expect(String(data: try await transport.read(), encoding: .utf8) == "* 3 EXISTS\r\nA2 OK\r\n")

        try await transport.send(Data("A1 CAPABILITY\r\n".utf8))
        #expect(String(data: try await transport.read(), encoding: .utf8)
                == "* CAPABILITY IMAP4rev1\r\nA1 OK\r\n")

        // Each rule fired once and is gone; a repeat gets nothing rather than a
        // stale replay.
        try await transport.send(Data("A3 SELECT INBOX\r\n".utf8))
        #expect(await transport.unreadChunkCount == 0)
    }

    @Test("A repeatable rule answers every matching command")
    func repeatableRule() async throws {
        let transport = ScriptedTransport()
        await transport.respond(to: "NOOP", with: "OK\r\n", repeatable: true)
        try await transport.connect()
        for _ in 0..<3 { try await transport.send(Data("A NOOP\r\n".utf8)) }
        #expect(await transport.unreadChunkCount == 3)
    }

    @Test("Everything the client sent is recorded verbatim and in order")
    func recordsSentBytes() async throws {
        let transport = ScriptedTransport()
        try await transport.connect()
        try await transport.send(Data("A1 LOGIN\r\n".utf8))
        try await transport.send(Data("A2 LOGOUT\r\n".utf8))
        #expect(await transport.sent.count == 2)
        #expect(await transport.sentText == "A1 LOGIN\r\nA2 LOGOUT\r\n")
    }

    // MARK: - The recorded upgrade point: the capability Tasks 9 and 15 depend on

    @Test("startTLS records the upgrade point so pre-TLS bytes can be audited")
    func recordsUpgradePoint() async throws {
        let transport = ScriptedTransport()
        try await transport.connect()
        #expect(await transport.upgradePoint == nil)

        try await transport.send(Data("A1 CAPABILITY\r\n".utf8))
        try await transport.send(Data("A2 STARTTLS\r\n".utf8))
        try await transport.startTLS()
        try await transport.send(Data("A3 LOGIN user hunter2\r\n".utf8))

        let point = try #require(await transport.upgradePoint)
        #expect(point == "A1 CAPABILITY\r\nA2 STARTTLS\r\n".utf8.count)
        #expect(await transport.upgradeSendIndex == 2)
        #expect(await transport.startTLSCount == 1)

        // The assertion shape Task 9 and Task 15 will use verbatim.
        let beforeUpgrade = String(data: await transport.bytesSentBeforeUpgrade, encoding: .utf8)
        #expect(beforeUpgrade == "A1 CAPABILITY\r\nA2 STARTTLS\r\n")
        #expect(beforeUpgrade?.contains("hunter2") == false)
        #expect(await transport.sentText.contains("hunter2"))
    }

    @Test("A second startTLS does not move the recorded upgrade point")
    func upgradePointIsFirstUpgrade() async throws {
        let transport = ScriptedTransport()
        try await transport.connect()
        try await transport.startTLS()
        try await transport.send(Data("X\r\n".utf8))
        try await transport.startTLS()
        #expect(await transport.upgradePoint == 0)
        #expect(await transport.startTLSCount == 2)
    }

    // MARK: - Lifecycle: no call may hang

    @Test("send/read/startTLS before connect throw notConnected")
    func requiresConnect() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue("* OK\r\n")
        await #expect(throws: MailTransportError.notConnected) { try await transport.read() }
        await #expect(throws: MailTransportError.notConnected) {
            try await transport.send(Data("A\r\n".utf8))
        }
        await #expect(throws: MailTransportError.notConnected) { try await transport.startTLS() }
    }

    @Test("An exhausted script fails the read instead of suspending it")
    func exhaustedScriptThrows() async throws {
        let transport = ScriptedTransport()
        try await transport.connect()
        await #expect(throws: (any Error).self) { try await transport.read() }
        do {
            _ = try await transport.read()
            Issue.record("expected scriptExhausted")
        } catch let error as MailTransportError {
            guard case .scriptExhausted = error else {
                Issue.record("expected scriptExhausted, got \(error)")
                return
            }
        }
    }

    @Test("After close every call throws closed and nothing stays readable")
    func closeFailsEverything() async throws {
        let transport = ScriptedTransport()
        try await transport.connect()
        await transport.enqueue("* OK\r\n")
        await transport.close()
        #expect(await transport.isClosed)
        #expect(await transport.unreadChunkCount == 0)
        await #expect(throws: MailTransportError.closed) { try await transport.read() }
        await #expect(throws: MailTransportError.closed) {
            try await transport.send(Data("A\r\n".utf8))
        }
        await #expect(throws: MailTransportError.closed) { try await transport.connect() }
    }

    // MARK: - The production conformer's declared limits

    /// `NetworkTransport` is exercised only for the behaviour that needs no
    /// socket. Live socket behaviour — a real TLS handshake, real chunk arrival,
    /// real peer close — is deferred to Task 24's live-verification checklist,
    /// and nothing here should be read as covering it.
    @Test("NetworkTransport refuses send/read before connect rather than hanging")
    func networkTransportRequiresConnect() async throws {
        let transport = NetworkTransport(
            endpoint: MailTransportEndpoint(host: "imap.invalid.test", port: 993, tls: .implicit))
        await #expect(throws: MailTransportError.notConnected) {
            try await transport.send(Data("A\r\n".utf8))
        }
        await #expect(throws: MailTransportError.notConnected) { try await transport.read() }
    }

    /// Was "refuses an in-place TLS upgrade with a typed error" until Task 15b,
    /// when `STARTTLSFramer` made the upgrade real and the blanket refusal wrong.
    /// The property worth keeping from it is the one that has nothing to do with
    /// TLS: `startTLS()` on an unconnected transport refuses immediately rather
    /// than suspending on a framer that will never start. The surviving
    /// `tlsUpgradeUnsupported` case is pinned by
    /// `STARTTLSFramerTests.implicitEndpointRefusesAnUpgrade`.
    @Test("NetworkTransport refuses an upgrade before connect rather than hanging")
    func networkTransportRefusesUpgradeBeforeConnect() async throws {
        let transport = NetworkTransport(
            endpoint: MailTransportEndpoint(host: "imap.invalid.test", port: 143, tls: .explicit))
        await #expect(throws: MailTransportError.notConnected) {
            try await transport.startTLS()
        }
    }

    @Test("NetworkTransport.close is idempotent and leaves every later call closed")
    func networkTransportCloseIsIdempotent() async throws {
        let transport = NetworkTransport(
            endpoint: MailTransportEndpoint(host: "imap.invalid.test", port: 993, tls: .implicit))
        await transport.close()
        await transport.close()
        await #expect(throws: MailTransportError.closed) { try await transport.read() }
        await #expect(throws: MailTransportError.closed) { try await transport.connect() }
    }
}
