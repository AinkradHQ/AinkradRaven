import Testing
import Foundation
@testable import RavenFeature

@Suite("IMAP SASL encoding")
struct IMAPSASLEncodingTests {

    @Test("the XOAUTH2 initial response is exactly user=…^Aauth=Bearer …^A^A")
    func xoauth2Layout() {
        let raw = IMAPAuthenticator.xoauth2InitialResponse(
            username: Fixture.address, accessToken: Fixture.accessToken)
        #expect(raw == Data("user=a@example.test\u{01}auth=Bearer access-token-secret\u{01}\u{01}".utf8))
        // Byte-level, because the ^A separators are invisible in a string diff and
        // getting them wrong is the classic XOAUTH2 bug.
        #expect([UInt8](raw).filter { $0 == 0x01 }.count == 3)
        #expect([UInt8](raw).last == 0x01)
        #expect(IMAPAuthenticator.base64(raw)
            == "dXNlcj1hQGV4YW1wbGUudGVzdAFhdXRoPUJlYXJlciBhY2Nlc3MtdG9rZW4tc2VjcmV0AQE=")
    }

    @Test("the PLAIN initial response is NUL authcid NUL passwd with an empty authzid")
    func plainLayout() {
        let raw = IMAPAuthenticator.plainInitialResponse(
            username: Fixture.address, password: Fixture.password)
        #expect([UInt8](raw).first == 0x00)
        #expect(raw == Data([0x00]) + Data("a@example.test".utf8) + Data([0x00])
                + Data("app-password-secret".utf8))
    }

    @Test("SASL-IR puts the base64 response on the command line")
    func saslIRInline() {
        let command = IMAPAuthenticator.xoauth2Command(
            username: Fixture.address, accessToken: Fixture.accessToken, saslIR: true)
        let plan = command.wirePlan(tag: "A001", allowNonSynchronizingLiterals: false)
        let expected = IMAPAuthenticator.base64(IMAPAuthenticator.xoauth2InitialResponse(
            username: Fixture.address, accessToken: Fixture.accessToken))
        #expect(String(decoding: plan.chunks[0], as: UTF8.self)
                == "A001 AUTHENTICATE XOAUTH2 \(expected)\r\n")
        // ONE chunk. The empty acknowledgement for the failure challenge is a
        // reactive line, not a chunk: a chunk would register the tag in the
        // session's continuation FIFO for a `+ ` the server usually never sends,
        // and that stolen `+ ` is what desynchronises a pipelined literal.
        #expect(plan.chunks.count == 1)
        #expect(command.reactiveContinuationLines == [Data("\r\n".utf8)])
        #expect(command.isExclusive)
    }

    @Test("without SASL-IR the response waits for the server's continuation request")
    func saslIRAbsent() {
        let command = IMAPAuthenticator.xoauth2Command(
            username: Fixture.address, accessToken: Fixture.accessToken, saslIR: false)
        let plan = command.wirePlan(tag: "A001", allowNonSynchronizingLiterals: false)
        #expect(String(decoding: plan.chunks[0], as: UTF8.self) == "A001 AUTHENTICATE XOAUTH2\r\n")
        #expect(plan.chunks.count == 1)
        // The credential is not in the command line — it is a reactive line, sent
        // only once the server has asked for it.
        #expect(String(decoding: plan.chunks[0], as: UTF8.self).contains("dXNlcj1h") == false)
        let expected = IMAPAuthenticator.base64(IMAPAuthenticator.xoauth2InitialResponse(
            username: Fixture.address, accessToken: Fixture.accessToken))
        #expect(command.reactiveContinuationLines
                == [Data("\(expected)\r\n".utf8), Data("\r\n".utf8)])
        #expect(command.isExclusive)
    }
}

@Suite("IMAP mechanism selection")
struct IMAPMechanismSelectionTests {

    @Test("LOGINDISABLED with no usable SASL mechanism refuses instead of choosing LOGIN")
    func loginDisabledRefuses() {
        #expect(throws: IMAPAuthError.plaintextLoginDisabled) {
            _ = try IMAPAuthenticator.command(
                for: .appPassword(username: Fixture.address, password: Fixture.password),
                capabilities: ["IMAP4REV1", "LOGINDISABLED"])
        }
    }

    @Test("LOGINDISABLED alongside AUTH=PLAIN uses AUTHENTICATE PLAIN, which it does not disable")
    func loginDisabledFallsBackToPlain() throws {
        let command = try IMAPAuthenticator.command(
            for: .appPassword(username: Fixture.address, password: Fixture.password),
            capabilities: ["IMAP4REV1", "LOGINDISABLED", "AUTH=PLAIN", "SASL-IR"])
        #expect(command.name == "AUTHENTICATE")
        #expect(command.description.contains("PLAIN"))
    }

    @Test("a plain server gets LOGIN")
    func plainServerGetsLogin() throws {
        let command = try IMAPAuthenticator.command(
            for: .appPassword(username: Fixture.address, password: Fixture.password),
            capabilities: ["IMAP4REV1"])
        #expect(command.name == "LOGIN")
    }

    @Test("XOAUTH2 that the server never advertised is refused, not attempted")
    func xoauth2Unavailable() {
        #expect(throws: IMAPAuthError.mechanismUnavailable("XOAUTH2")) {
            _ = try IMAPAuthenticator.command(
                for: .xoauth2(username: Fixture.address, accessToken: Fixture.accessToken),
                capabilities: ["IMAP4REV1", "AUTH=PLAIN"])
        }
    }
}

@Suite("IMAP authentication over the wire")
struct IMAPAuthWireTests {

    @Test("LOGINDISABLED refuses without writing one byte to the transport")
    func loginDisabledWritesNothing() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 LOGINDISABLED")
        defer { Task { await session.close() } }
        // A LOGIN that would SUCCEED if it were attempted — see
        // `explicitTLSRefused` for why an exhausted script is the wrong shape
        // here: it makes the test pass for the wrong reason under mutation.
        await transport.respond(to: "LOGIN", with: "A0001 OK LOGIN completed\r\n")
        await transport.respond(to: "CAPABILITY", with: "* CAPABILITY IMAP4rev1\r\nA0002 OK done\r\n")
        let auth = IMAPAuthenticator(session: session, security: .implicit)

        await expectAuthFailure(IMAPAuthError.plaintextLoginDisabled) {
            try await auth.authenticate(
                .appPassword(username: Fixture.address, password: Fixture.password),
                greeting: greeting)
        }
        // The recorded bytes are the proof: not "a LOGIN that failed", but no
        // LOGIN at all. The greeting's [CAPABILITY …] code means not even a
        // CAPABILITY command was needed.
        #expect(await transport.sent.isEmpty)
        #expect(await transport.sentText == "")
        #expect(await transport.sentText.contains(Fixture.password) == false)
    }

    /// Task 15b turned this branch from a refusal into an upgrade, because
    /// `NetworkTransport` can now genuinely perform one (`STARTTLSFramer`). The
    /// property the old refusal existed to guarantee — no credential byte on a
    /// plaintext socket — is unchanged and is what this pins, by the same
    /// `bytesSentBeforeUpgrade` mechanism `SMTPSessionTests.explicitTLS` uses.
    ///
    /// The pre-upgrade prefix is asserted **exactly and non-empty**. Exactly,
    /// because `#expect(prefix.contains(password) == false)` alone passes for a
    /// build that never got as far as sending anything; non-empty, because it is
    /// what distinguishes "the upgrade came after the negotiation" from "there was
    /// no negotiation".
    @Test("an explicit-STARTTLS configuration upgrades before any credential byte")
    func explicitTLSUpgradesFirst() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 STARTTLS LOGINDISABLED")
        defer { Task { await session.close() } }
        await transport.respond(to: "STARTTLS", with: "A0001 OK begin TLS\r\n")
        // The plaintext list says LOGINDISABLED and offers no mechanism; the
        // post-TLS one offers AUTH=PLAIN. So an implementation that authenticated
        // from the pre-TLS list could not succeed at all, and one that skipped the
        // mandatory re-read would refuse — which is what makes this fixture
        // distinguish the rule from the plausible wrong one.
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR\r\nA0002 OK done\r\n")
        await transport.respond(to: "AUTHENTICATE PLAIN", with: "A0003 OK authenticated\r\n")
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 IDLE\r\nA0004 OK done\r\n")
        let auth = IMAPAuthenticator(session: session, security: .explicit)

        let after = try #require(await expectAuthSuccess {
            try await auth.authenticate(
                .appPassword(username: Fixture.address, password: Fixture.password),
                greeting: greeting)
        })

        #expect(await transport.startTLSCount == 1)
        let before = await transport.bytesSentBeforeUpgrade
        #expect(String(decoding: before, as: UTF8.self) == "A0001 STARTTLS\r\n")
        #expect(before.isEmpty == false)
        #expect(String(decoding: before, as: UTF8.self).contains(Fixture.password) == false)
        // And the credential really was sent — after the upgrade. Pinned as a
        // literal so this cannot pass by nothing having happened.
        #expect(await transport.sentText == """
        A0001 STARTTLS\r
        A0002 CAPABILITY\r
        A0003 AUTHENTICATE PLAIN AGFAZXhhbXBsZS50ZXN0AGFwcC1wYXNzd29yZC1zZWNyZXQ=\r
        A0004 CAPABILITY\r

        """)
        #expect(after.contains("IDLE"))
    }

    @Test("a plaintext server that never offered STARTTLS is refused, not logged into")
    func explicitTLSUnadvertisedRefused() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 AUTH=PLAIN SASL-IR")
        defer { Task { await session.close() } }
        // A COMPLETE dialogue that would succeed if it were attempted — including
        // a `STARTTLS` the server never advertised but would nonetheless honour —
        // and socket-like idle reads. Both are the shape
        // `loginDisabledWritesNothing` documents: with an exhausted script the
        // assertions below would pass because the session tore down, not because
        // the refusal held.
        await transport.respond(to: "STARTTLS", with: "A0001 OK begin TLS\r\n")
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR\r\nA0002 OK done\r\n")
        await transport.respond(to: "AUTHENTICATE PLAIN", with: "A0003 OK authenticated\r\n")
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 IDLE\r\nA0004 OK done\r\n")
        let auth = IMAPAuthenticator(session: session, security: .explicit)

        await expectAuthFailure(IMAPAuthError.startTLSUnadvertised) {
            try await auth.authenticate(
                .appPassword(username: Fixture.address, password: Fixture.password),
                greeting: greeting)
        }
        // Nothing at all on the wire: the greeting's [CAPABILITY …] code answered
        // the only question that had to be asked, and the refusal is upstream of
        // every write.
        #expect(await transport.sent.isEmpty)
        #expect(await transport.sentText.contains(Fixture.password) == false)
        #expect(await transport.startTLSCount == 0)
        #expect(await transport.upgradePoint == nil)
    }

    /// ## What this test does and does NOT prove about acceptance criterion 3
    ///
    /// It proves the successful XOAUTH2 exchange: the SASL-IR base64 response goes
    /// out on the command line and the capability list is re-read afterwards.
    ///
    /// It does NOT prove "no credential byte before TLS is active" for the
    /// implicit path, and an earlier version of it claimed to. On implicit TLS the
    /// handshake happens *inside* `connect()`, and `MailTransport.send` requires a
    /// connected transport — so "TLS is active before the first byte" is true by
    /// construction, for every possible implementation of this layer, and any
    /// assertion of it is unfalsifiable. The gate demonstrated that: a probe that
    /// sent `LOGIN "a@b.test" "SECRET"` as the very first write still reported
    /// `upgradePoint = 0` and an empty pre-upgrade prefix. Those two assertions
    /// have been deleted rather than left standing with a comment overclaiming
    /// them.
    ///
    /// Criterion 3 is therefore carried by `explicitTLSUpgradesFirst` alone, which
    /// is falsifiable and mutation-verified: it is the only branch where a real
    /// implementation choice (upgrade first vs. authenticate first) exists, and
    /// the only one where `bytesSentBeforeUpgrade` is a non-empty, exact prefix.
    @Test("an XOAUTH2 login writes the base64 SASL response and re-reads capabilities")
    func xoauth2LoginWritesTheSASLResponse() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 AUTH=XOAUTH2 SASL-IR")
        defer { Task { await session.close() } }
        await transport.respond(to: "AUTHENTICATE XOAUTH2", with: "A0001 OK authenticated\r\n")
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 IDLE\r\nA0002 OK done\r\n")

        let auth = IMAPAuthenticator(session: session, security: .implicit)
        let after = try #require(await expectAuthSuccess {
            try await auth.authenticate(
                .xoauth2(username: Fixture.address, accessToken: Fixture.accessToken),
                greeting: greeting)
        })

        // Pinned literal rather than a self-referential re-derivation.
        #expect(await transport.sentText == """
        A0001 AUTHENTICATE XOAUTH2 \
        dXNlcj1hQGV4YW1wbGUudGVzdAFhdXRoPUJlYXJlciBhY2Nlc3MtdG9rZW4tc2VjcmV0AQE=\r
        A0002 CAPABILITY\r

        """)
        // The success path sent exactly two writes: the speculative SASL ack was
        // NOT written, because the server never asked for it.
        #expect(await transport.sent.count == 2)
        // Post-auth capabilities were re-read, so IDLE is visible.
        #expect(after.contains("IDLE"))
    }

    @Test("an app password logs in with LOGIN and the capability list is re-read")
    func appPasswordLogin() async throws {
        let (session, transport, greeting) = try await makeAuthSession(capabilities: "IMAP4rev1")
        defer { Task { await session.close() } }
        await transport.respond(to: "LOGIN", with: "A0001 OK LOGIN completed\r\n")
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 IDLE UIDPLUS\r\nA0002 OK done\r\n")

        let auth = IMAPAuthenticator(session: session, security: .implicit)
        let after = try #require(await expectAuthSuccess {
            try await auth.authenticate(
                .appPassword(username: Fixture.address, password: Fixture.password),
                greeting: greeting)
        })

        #expect(await transport.sentText
                == "A0001 LOGIN \"a@example.test\" \"app-password-secret\"\r\nA0002 CAPABILITY\r\n")
        #expect(after == ["IMAP4REV1", "IDLE", "UIDPLUS"])
    }

    @Test("an XOAUTH2 failure challenge is answered with an empty line before the tagged NO")
    func xoauth2FailureChallenge() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 AUTH=XOAUTH2 SASL-IR")
        defer { Task { await session.close() } }
        // The mechanism reports failure as a base64 JSON *challenge*, not as a
        // tagged completion. Until the client acknowledges it the server sends no
        // NO, so a client that just waits hangs forever.
        await transport.respond(to: "AUTHENTICATE XOAUTH2",
                                with: "+ eyJzdGF0dXMiOiI0MDEifQ==\r\n")
        await transport.respond(to: "\r\n", with: "A0001 NO Invalid credentials\r\n")

        let auth = IMAPAuthenticator(session: session, security: .implicit)
        await expectAuthFailure(IMAPAuthError.rejected("Invalid credentials")) {
            try await auth.authenticate(
                .xoauth2(username: Fixture.address, accessToken: Fixture.accessToken),
                greeting: greeting)
        }
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(sent.last == Data("\r\n".utf8))
    }

    @Test("SASL PLAIN goes over the wire as AUTHENTICATE PLAIN with the base64 response")
    func plainLoginOverTheWire() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 LOGINDISABLED AUTH=PLAIN SASL-IR")
        defer { Task { await session.close() } }
        await transport.respond(to: "AUTHENTICATE PLAIN", with: "A0001 OK authenticated\r\n")
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 IDLE\r\nA0002 OK done\r\n")

        let auth = IMAPAuthenticator(session: session, security: .implicit)
        let after = try #require(await expectAuthSuccess {
            try await auth.authenticate(
                .appPassword(username: Fixture.address, password: Fixture.password),
                greeting: greeting)
        })

        // base64("\0a@example.test\0app-password-secret"), pinned as a literal.
        #expect(await transport.sentText == """
        A0001 AUTHENTICATE PLAIN AGFAZXhhbXBsZS50ZXN0AGFwcC1wYXNzd29yZC1zZWNyZXQ=\r
        A0002 CAPABILITY\r

        """)
        #expect(after.contains("IDLE"))
    }

    @Test("a PREAUTH greeting authenticates nothing")
    func preauthSendsNoCredential() async throws {
        // Socket-like idle reads, and a LOGIN/AUTHENTICATE that would SUCCEED.
        // With `.throwScriptExhausted` (the shape this test originally had) the
        // read loop tore the session down straight after the greeting, so deleting
        // the PREAUTH short-circuit failed with `scriptExhausted` — proving
        // teardown, not "no credential byte", and line-`sent.isEmpty` was never
        // reached. As written, losing the short-circuit completes a LOGIN and puts
        // the password in `sentText`.
        let transport = ScriptedTransport(idleReads: .suspend)
        await transport.enqueue("* PREAUTH [CAPABILITY IMAP4rev1 IDLE] tunnelled\r\n")
        await transport.respond(to: "LOGIN", with: "A0001 OK LOGIN completed\r\n")
        await transport.respond(to: "AUTHENTICATE", with: "A0001 OK authenticated\r\n")
        await transport.respond(to: "CAPABILITY",
                                with: "* CAPABILITY IMAP4rev1 IDLE\r\nA0002 OK done\r\n")
        let session = IMAPSession(transport: transport)
        let greeting = try await session.connect()
        defer { Task { await session.close() } }
        #expect(greeting.kind == .preauth)

        let auth = IMAPAuthenticator(session: session, security: .implicit)
        let after = try #require(await expectAuthSuccess {
            try await auth.authenticate(
                .appPassword(username: Fixture.address, password: Fixture.password),
                greeting: greeting)
        })
        #expect(after.contains("IDLE"))
        #expect(await transport.sentText.contains(Fixture.password) == false)
        #expect(await transport.sent.isEmpty)
    }
}