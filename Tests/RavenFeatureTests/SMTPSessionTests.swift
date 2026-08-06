import Testing
import Foundation
@testable import RavenFeature

@Suite("SMTP reply parsing")
struct SMTPReplyParserTests {
    @Test("a single-line reply is code plus text")
    func singleLine() throws {
        let reply = try SMTPReplyParser.parse("250 2.0.0 Ok\r\n")
        #expect(reply == SMTPReply(code: 250, lines: ["2.0.0 Ok"]))
        #expect(reply.isPositive)
        #expect(!reply.isTransient)
        #expect(!reply.isPermanent)
    }

    /// The recorded `EHLO` reply, from the fixture, byte for byte. Every
    /// continuation line must survive: a parser that read only the first line
    /// would report a server with no `STARTTLS` and no `AUTH` — a plausible
    /// answer, and the one that silently downgrades security.
    @Test("every continuation line of a multiline reply is kept, in order")
    func multiline() throws {
        let reply = try SMTPReplyParser.parse(try SMTPHarness.fixtureText("smtp-ehlo-multiline"))
        #expect(reply.code == 250)
        #expect(reply.lines == ["mail.example.test greets [127.0.0.1]",
                                "SIZE 35882577",
                                "8BITMIME",
                                "STARTTLS",
                                "AUTH LOGIN PLAIN XOAUTH2",
                                "ENHANCEDSTATUSCODES",
                                "SMTPUTF8"])
    }

    @Test("a final line with no separator and no text is legal")
    func bareCode() throws {
        #expect(try SMTPReplyParser.parse("250\r\n") == SMTPReply(code: 250, lines: [""]))
    }

    /// RFC 5321 §4.2.1: every line of one reply carries the same code. A mismatch
    /// means two replies were read as one, which is how a desynchronised stream
    /// first shows up — and blending them would produce a plausible-looking reply
    /// with the wrong code.
    @Test("a continuation line with a different code is malformed, not blended")
    func codeMismatch() {
        #expect(throws: SMTPSessionError.self) {
            _ = try SMTPReplyParser.parse("250-first\r\n550 second\r\n")
        }
    }

    @Test("a line after the final line is malformed")
    func trailingLine() {
        #expect(throws: SMTPSessionError.self) {
            _ = try SMTPReplyParser.parse("250 done\r\n250 again\r\n")
        }
    }

    @Test("lines with no code, a short code or an illegal separator are refused",
          arguments: ["ok\r\n", "25\r\n", "250x ok\r\n", "abc def\r\n", "999 ok\r\n"])
    func malformedLines(text: String) {
        #expect(throws: SMTPSessionError.self) { _ = try SMTPReplyParser.parse(text) }
    }

    /// The 4xx/5xx split, on the exact codes the criteria name, plus the mapping
    /// onto the outbox's own error vocabulary.
    @Test("4yz is transient and 5yz is permanent")
    func classification() throws {
        let transient = try SMTPReplyParser.parse("451 4.3.0 try later\r\n")
        #expect(transient.isTransient && !transient.isPermanent)
        let permanent = try SMTPReplyParser.parse("550 5.1.1 no such user\r\n")
        #expect(permanent.isPermanent && !permanent.isTransient)

        #expect(SMTPSessionError.transientFailure(code: 451, text: "t").mailError
                    == .providerFailed(status: 451, message: "t"))
        #expect(SMTPSessionError.permanentFailure(code: 550, text: "p").mailError
                    == .sendRefused(status: 550, message: "p"))
        #expect(SMTPSessionError.outcomeUnknown("u").mailError == .sendOutcomeUnknown(message: "u"))
    }

    /// `OutboxFailure` is the other half of that mapping: which fate each error
    /// gets. Asserted here as a pure function, and end-to-end through a real
    /// `Outbox` in `SMTPSubmitterTests`.
    @Test("only a permanent refusal skips the retry, and only an unknown outcome is held")
    func dispositions() {
        #expect(OutboxFailure.disposition(for: MailError.sendRefused(status: 550, message: "x"))
                    == .deadLetter)
        #expect(OutboxFailure.disposition(for: MailError.sendOutcomeUnknown(message: "x"))
                    == .review)
        #expect(OutboxFailure.disposition(for: MailError.providerFailed(status: 451, message: "x"))
                    == .retry)
        #expect(OutboxFailure.disposition(for: MailError.rateLimited(retryAfter: 1)) == .retry)
    }
}

@Suite("SMTP session — both TLS modes")
struct SMTPSessionTLSTests {
    /// 465: TLS is part of `connect()`, so the session is encrypted before the
    /// greeting and never negotiates an upgrade.
    @Test("implicit TLS authenticates with no STARTTLS at all")
    func implicitTLS() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        let session = SMTPSession(transport: transport, security: .implicit,
                                  clientDomain: "[127.0.0.1]")

        await SMTPHarness.expectSuccess {
            try await session.connect()
            try await session.authenticate(.appPassword(username: SMTPHarness.address,
                                                        password: SMTPHarness.password))
        }

        #expect(await session.isEncrypted)
        #expect(await transport.startTLSCount == 0)
        #expect(await transport.upgradePoint == nil)
        // The whole plaintext-negotiation vocabulary is absent, not merely unused.
        #expect(await transport.sentText.contains("STARTTLS") == false)
        #expect(await session.extensions.contains("STARTTLS"))  // advertised, and ignored
        #expect(await session.authMechanisms == ["LOGIN", "PLAIN", "XOAUTH2"])
    }

    /// 587, the criterion in full: the upgrade happens, and **no `AUTH` byte
    /// precedes it**.
    ///
    /// The assertion is whole-collection equality on the sends recorded *before*
    /// `ScriptedTransport.startTLS()` was called, which makes it falsifiable in
    /// both directions:
    ///
    /// - it fails if anything extra is written before the upgrade (an `AUTH`, a
    ///   `MAIL FROM`, a second `EHLO`);
    /// - **and it fails if nothing is written before the upgrade at all.** That is
    ///   the half that matters. "No credential before TLS" is trivially true of a
    ///   transport that records its upgrade point inside `connect()`, and that
    ///   exact vacuity has already appeared on this branch. Here the expected
    ///   prefix is non-empty and exact — `EHLO` then `STARTTLS` — so an
    ///   implementation that upgraded too early fails just as loudly as one that
    ///   upgraded too late.
    @Test("STARTTLS upgrades before any AUTH byte is written")
    func explicitTLS() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptSTARTTLSLogin(transport)
        let session = SMTPSession(transport: transport, security: .explicit,
                                  clientDomain: "[127.0.0.1]")

        #expect(await session.isEncrypted == false)
        await SMTPHarness.expectSuccess {
            try await session.connect()
            try await session.upgradeToTLS()
            try await session.authenticate(.appPassword(username: SMTPHarness.address,
                                                        password: SMTPHarness.password))
        }

        #expect(await transport.startTLSCount == 1)
        let index = try #require(await transport.upgradeSendIndex)
        let before = await transport.sent.prefix(index).map { String(decoding: $0, as: UTF8.self) }
        #expect(before == ["EHLO [127.0.0.1]\r\n", "STARTTLS\r\n"])

        // The positive control: the credential IS sent — after the upgrade. Without
        // this, every assertion above would also hold for a session that simply
        // never authenticated.
        let after = await transport.sent.dropFirst(index).map { String(decoding: $0, as: UTF8.self) }
        let payload = SASLMechanism.base64(
            SASLMechanism.plainInitialResponse(username: SMTPHarness.address,
                                               password: SMTPHarness.password))
        #expect(after == ["EHLO [127.0.0.1]\r\n", "AUTH PLAIN " + payload + "\r\n"])
        #expect(await session.isEncrypted)
    }

    /// The credential-leak assertion, on the bytes that crossed the wire in
    /// plaintext. Distinct from the byte-equality above: that one pins *what* was
    /// written, this one pins that the secret is nowhere inside it, including
    /// base64'd.
    @Test("no credential byte, raw or base64, precedes the upgrade")
    func noCredentialBeforeUpgrade() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptSTARTTLSLogin(transport)
        let session = SMTPSession(transport: transport, security: .explicit)
        await SMTPHarness.expectSuccess {
            try await session.connect()
            try await session.upgradeToTLS()
            try await session.authenticate(.appPassword(username: SMTPHarness.address,
                                                        password: SMTPHarness.password))
        }
        let plaintext = String(decoding: await transport.bytesSentBeforeUpgrade, as: UTF8.self)
        #expect(plaintext.isEmpty == false,
                "nothing was sent before the upgrade — the assertions below would then hold for any implementation")
        #expect(plaintext.contains(SMTPHarness.password) == false)
        #expect(plaintext.contains(SASLMechanism.base64(
            SASLMechanism.plainInitialResponse(username: SMTPHarness.address,
                                               password: SMTPHarness.password))) == false)
        #expect(plaintext.contains("AUTH") == false)
    }

    /// `AUTH` is refused by the session itself on an unencrypted connection, so
    /// "no credential before TLS" is a property of this type rather than of the
    /// order in which `SMTPSubmitter` happens to call it.
    @Test("AUTH on a plaintext connection is refused before a byte is written")
    func authRefusedInPlaintext() async throws {
        let transport = await SMTPHarness.transport()
        await transport.respond(to: "EHLO", with: try SMTPHarness.fixtureText("smtp-ehlo-multiline"))
        // Scripted so the forbidden command would SUCCEED if it were sent: a
        // session that wrote it gets a 235 back and this test still fails, rather
        // than passing because the dialogue died early.
        await transport.respond(to: "AUTH", with: "235 2.7.0 accepted\r\n")
        let session = SMTPSession(transport: transport, security: .explicit)
        await SMTPHarness.expectSuccess { try await session.connect() }
        await SMTPHarness.expectFailure(.notEncrypted) {
            try await session.authenticate(.appPassword(username: SMTPHarness.address,
                                                        password: SMTPHarness.password))
        }
        #expect(await transport.sentText.contains("AUTH") == false)
        #expect(await transport.sentText.contains(SMTPHarness.password) == false)
    }

    @Test("an upgrade is refused outright when STARTTLS was not advertised")
    func starttlsUnadvertised() async throws {
        let transport = await SMTPHarness.transport()
        await transport.respond(to: "EHLO", with: try SMTPHarness.fixtureText("smtp-ehlo-secured"))
        await transport.respond(to: "STARTTLS", with: "220 2.0.0 ready to start TLS\r\n")
        let session = SMTPSession(transport: transport, security: .explicit)
        await SMTPHarness.expectSuccess { try await session.connect() }
        await SMTPHarness.expectFailure(.startTLSUnadvertised) { try await session.upgradeToTLS() }
        #expect(await transport.startTLSCount == 0)
        #expect(await transport.sentText.contains("STARTTLS") == false)
    }

    /// The still-open decision, recorded as a test rather than as prose: the
    /// production transport cannot upgrade in place, and the session reports that
    /// as its own typed case instead of continuing in plaintext.
    @Test("a transport that cannot upgrade in place fails loudly, never silently")
    func transportCannotUpgrade() async throws {
        let transport = NonUpgradableTransport(
            greeting: SMTPHarness.greeting,
            ehlo: try SMTPHarness.fixtureText("smtp-ehlo-plaintext"))
        let session = SMTPSession(transport: transport, security: .explicit)
        await SMTPHarness.expectSuccess { try await session.connect() }
        await SMTPHarness.expectFailure(.tlsUpgradeUnsupported) { try await session.upgradeToTLS() }
        #expect(await session.isEncrypted == false)
    }

    /// A transport that answers the plaintext dialogue and then refuses to
    /// upgrade, exactly as `NetworkTransport` does. Not `ScriptedTransport`,
    /// because that one CAN upgrade — which is what makes every other test here
    /// possible, and why this one needs a different double.
    private actor NonUpgradableTransport: MailTransport {
        private var pending: [Data]
        private let ehlo: Data
        init(greeting: String, ehlo: String) {
            self.pending = [Data(greeting.utf8)]
            self.ehlo = Data(ehlo.utf8)
        }
        func connect() async throws {}
        func send(_ bytes: Data) async throws {
            let line = String(decoding: bytes, as: UTF8.self)
            if line.hasPrefix("EHLO") { pending.append(ehlo) }
            // The server AGREES to the upgrade; it is the transport that cannot
            // perform it. That is the whole point of this double — a script that
            // refused at the protocol level would test a different thing.
            if line.hasPrefix("STARTTLS") { pending.append(Data("220 2.0.0 go ahead\r\n".utf8)) }
        }
        func read() async throws -> Data {
            guard !pending.isEmpty else { throw MailTransportError.closed }
            return pending.removeFirst()
        }
        func startTLS() async throws { throw MailTransportError.tlsUpgradeUnsupported }
        func close() async {}
    }
}

@Suite("SMTP session — authentication and failure mapping")
struct SMTPSessionAuthTests {
    /// The SMTP framing of the XOAUTH2 payload, byte for byte, and the failure
    /// challenge it uniquely needs: a refusal arrives as `334 <base64 json>`, and
    /// the server does not send its final code until the client acknowledges with
    /// an empty line. Same shape as `IMAPAuth`'s `answersFailureChallenge`.
    @Test("XOAUTH2 sends the shared SASL payload and answers the failure challenge")
    func xoauth2FailureChallenge() async throws {
        let transport = await SMTPHarness.transport()
        await transport.respond(to: "EHLO", with: try SMTPHarness.fixtureText("smtp-ehlo-secured"))
        await transport.respond(to: "AUTH XOAUTH2", with: "334 eyJzdGF0dXMiOiI0MDEifQ==\r\n")
        await transport.respond(to: "\r\n", with: "535 5.7.8 credentials rejected\r\n")
        let session = SMTPSession(transport: transport, security: .implicit)
        await SMTPHarness.expectSuccess { try await session.connect() }
        await SMTPHarness.expectFailure(.authenticationRefused(code: 535,
                                                              text: "5.7.8 credentials rejected")) {
            try await session.authenticate(.xoauth2(username: SMTPHarness.address,
                                                    accessToken: SMTPHarness.accessToken))
        }
        let expected = "AUTH XOAUTH2 " + SASLMechanism.base64(
            SASLMechanism.xoauth2InitialResponse(username: SMTPHarness.address,
                                                 accessToken: SMTPHarness.accessToken)) + "\r\n"
        let sent = await transport.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(sent == ["EHLO [127.0.0.1]\r\n", expected, "\r\n"])
    }

    @Test("a credential whose mechanism was not advertised is never written")
    func mechanismUnavailable() async throws {
        let transport = await SMTPHarness.transport()
        await transport.respond(to: "EHLO", with: "250-mail.example.test greets\r\n250 8BITMIME\r\n")
        await transport.respond(to: "AUTH", with: "235 2.7.0 accepted\r\n")
        let session = SMTPSession(transport: transport, security: .implicit)
        await SMTPHarness.expectSuccess { try await session.connect() }
        await SMTPHarness.expectFailure(.mechanismUnavailable("PLAIN")) {
            try await session.authenticate(.appPassword(username: SMTPHarness.address,
                                                        password: SMTPHarness.password))
        }
        #expect(await transport.sentText.contains("AUTH") == false)
    }

    /// `AUTH LOGIN` is the fallback when `PLAIN` is absent — and its two base64
    /// challenges are the only place a password crosses the wire outside a single
    /// SASL blob, so its bytes are pinned exactly.
    @Test("AUTH LOGIN is used only when PLAIN is absent, and sends both challenges")
    func authLogin() async throws {
        let transport = await SMTPHarness.transport()
        await transport.respond(to: "EHLO",
                                with: "250-mail.example.test greets\r\n250 AUTH LOGIN\r\n")
        await transport.respond(to: "AUTH LOGIN", with: "334 VXNlcm5hbWU6\r\n")
        let user = SASLMechanism.base64(Data(SMTPHarness.address.utf8))
        await transport.respond(to: user, with: "334 UGFzc3dvcmQ6\r\n")
        let secret = SASLMechanism.base64(Data(SMTPHarness.password.utf8))
        await transport.respond(to: secret, with: "235 2.7.0 accepted\r\n")
        let session = SMTPSession(transport: transport, security: .implicit)
        await SMTPHarness.expectSuccess {
            try await session.connect()
            try await session.authenticate(.appPassword(username: SMTPHarness.address,
                                                        password: SMTPHarness.password))
        }
        let sent = await transport.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(sent == ["EHLO [127.0.0.1]\r\n", "AUTH LOGIN\r\n",
                         user + "\r\n", secret + "\r\n"])
    }

    /// Nothing this session keeps in memory for a test (or a log) to find carries
    /// the credential: the recorded verb list holds a redacted stand-in.
    @Test("the session's own record of what it sent carries no credential")
    func issuedVerbsAreRedacted() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        let session = SMTPSession(transport: transport, security: .implicit)
        await SMTPHarness.expectSuccess {
            try await session.connect()
            try await session.authenticate(.appPassword(username: SMTPHarness.address,
                                                        password: SMTPHarness.password))
        }
        let verbs = await session.issuedVerbs
        #expect(verbs == ["EHLO [127.0.0.1]", "AUTH PLAIN"])
        #expect(verbs.joined().contains(SMTPHarness.password) == false)
    }

    /// The source-level tripwire, in the same spirit as `OAuthTokenStorageTests`:
    /// if the SMTP files ever gain a document store or a logging call, this fails
    /// and whoever added it has to justify it here. Comments are stripped first,
    /// because these files SHOULD discuss the invariant in prose.
    @Test("the SMTP path has no document store and no logger to leak through")
    func smtpCannotReachDocumentsOrLogs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RavenFeatureTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
        let files = ["Sources/RavenFeature/Provider/SMTP/SMTPSession.swift",
                     "Sources/RavenFeature/Provider/SMTP/SMTPSubmitter.swift",
                     "Sources/RavenFeature/Provider/SMTP/SMTPReply.swift",
                     "Sources/RavenFeature/Provider/SASLMechanism.swift"]
        for path in files {
            let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
            #expect(code.contains("PluginDocumentStore") == false, "\(path)")
            #expect(code.contains("PluginSecretStore") == false, "\(path)")
            #expect(code.contains("host.documents") == false, "\(path)")
            #expect(code.contains("print(") == false, "\(path)")
            #expect(code.contains("NSLog") == false, "\(path)")
        }
    }

    @Test("fixtures are redacted",
          arguments: ["smtp-ehlo-multiline", "smtp-ehlo-plaintext", "smtp-ehlo-secured"])
    func fixturesAreRedacted(name: String) throws {
        let text = try SMTPHarness.fixtureText(name)
        for field in text.split(whereSeparator: { " <>\"()".contains($0) })
            where field.contains("@") {
            #expect(field.hasSuffix("example.test>") || field.hasSuffix("example.test"),
                    "non-redacted address \(field) in \(name)")
        }
        #expect(text.hasSuffix("\r\n"), "\(name) must be CRLF-terminated")
    }
}
