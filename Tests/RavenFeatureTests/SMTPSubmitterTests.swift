import Testing
import Foundation
@testable import RavenFeature

@Suite("SMTP submission — envelope, Bcc and dot-stuffing")
struct SMTPSubmitterAssemblyTests {
    /// **Both halves, in one test.** The envelope must name the blind recipient
    /// (or they never receive the mail) and the transmitted headers must not (or
    /// every other recipient learns who they were). Asserting only the header half
    /// would pass for an implementation that dropped the bcc recipient entirely;
    /// asserting only the envelope half would pass for one that leaked the header.
    ///
    /// This is the exact inverse of `GmailRFC822`'s rule, which passes
    /// `includeBccHeader: true` because Gmail derives the envelope from the
    /// headers. That file is untouched, and the two policies are why
    /// `RFC822Builder.includeBccHeader` has no default value.
    @Test("the envelope carries bcc and the transmitted data carries no Bcc header")
    func bccIsInTheEnvelopeOnly() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await SMTPHarness.scriptTransaction(transport)
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.implicitEndpoint)
        let message = SMTPHarness.message()

        let id = await SMTPHarness.expectSuccess { try await submitter.submit(message) }
        #expect(id == "2.0.0 Ok: queued as QUEUEID")

        let sent = await transport.sent.map { String(decoding: $0, as: UTF8.self) }
        // Whole-collection equality on the envelope commands, so nothing can sit
        // between two expected writes and no recipient can be missing or extra.
        let envelopeCommands = sent.filter {
            $0.hasPrefix("MAIL FROM") || $0.hasPrefix("RCPT TO")
        }
        #expect(envelopeCommands == ["MAIL FROM:<a@example.test>\r\n",
                                     "RCPT TO:<to@example.test>\r\n",
                                     "RCPT TO:<cc@example.test>\r\n",
                                     "RCPT TO:<blind@example.test>\r\n"])

        // The other half: the transmitted message itself.
        let data = try #require(await SMTPHarness.transmittedData(transport))
        #expect(data.contains("Bcc:") == false)
        #expect(data.contains("blind@example.test") == false)
        // And the headers that DO belong are there — otherwise "no Bcc" would also
        // hold for an empty message.
        #expect(data.contains("To: to@example.test\r\n"))
        #expect(data.contains("Cc: cc@example.test\r\n"))
    }

    /// The envelope is assembled without a transport too, so the rule is pinned
    /// as a pure function as well as on the wire. De-duplication matters: an
    /// address in both `to` and `bcc` would otherwise get two `RCPT TO` commands
    /// and, on some servers, two delivered copies.
    @Test("the envelope is to + cc + bcc, in order, de-duplicated case-insensitively")
    func envelopeOrderAndDeduplication() {
        let message = OutgoingMessage(
            to: [MailAddress(email: "to@example.test")],
            cc: [MailAddress(email: "cc@example.test"), MailAddress(email: "TO@example.test")],
            bcc: [MailAddress(email: "blind@example.test"), MailAddress(email: "cc@example.test")],
            subject: "Subject 1", bodyText: "Body 1")
        #expect(SMTPSubmitter.envelope(for: message, sender: "a@example.test")
                == SMTPEnvelope(sender: "a@example.test",
                                recipients: ["to@example.test", "cc@example.test",
                                             "blind@example.test"]))
    }

    /// RFC 5321 §4.5.2 transparency. The undotted body line is the trap: without
    /// stuffing, the message ends at that line and everything after it is read as
    /// SMTP commands — a truncated delivery, not a visible error.
    ///
    /// **This is a pure-function test and can only be one.** No message
    /// `RFC822Builder` can currently produce contains a stuffable line — every body
    /// part is base64, and no other line of an assembled message can begin with a
    /// `.` — so there is no input to `submit` that would exercise the stuffing
    /// branch on the wire. The call site itself is covered only by `terminator()`'s
    /// `\r\n.\r\n` tail check. See `SMTPSubmitter.dotStuffed`, which records why the
    /// unconditional stuffing stays anyway.
    @Test("a body line beginning with a dot is stuffed, and only the leading dot is")
    func dotStuffing() {
        let stuffed = SMTPSubmitter.dotStuffed(
            "Header: v\r\n\r\n.\r\n.hidden\r\n..already\r\nnot. a dot\r\n")
        #expect(String(decoding: stuffed, as: UTF8.self)
                == "Header: v\r\n\r\n..\r\n..hidden\r\n...already\r\nnot. a dot\r\n")
    }

    @Test("the payload always ends in exactly one CRLF, whatever the input did")
    func payloadEndsInOneCRLF() {
        #expect(String(decoding: SMTPSubmitter.dotStuffed("a\r\n"), as: UTF8.self) == "a\r\n")
        #expect(String(decoding: SMTPSubmitter.dotStuffed("a"), as: UTF8.self) == "a\r\n")
    }

    /// The terminator, on the real wire: the transmitted chunk ends with
    /// `CRLF.CRLF` and the dot-stuffing survived assembly through
    /// `RFC822Builder`. The body here is base64'd inside the MIME parts, so the
    /// *header* region is where a raw leading dot can appear — the assertion is on
    /// the exact tail either way.
    @Test("the message terminates with CRLF.CRLF")
    func terminator() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await SMTPHarness.scriptTransaction(transport)
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.implicitEndpoint)
        _ = await SMTPHarness.expectSuccess { try await submitter.submit(SMTPHarness.message()) }

        let text = try #require(await SMTPHarness.transmittedData(transport))
        #expect(text.hasSuffix("\r\n.\r\n"))
        // Not merely "ends with a dot line": the dot must be the ONLY thing on its
        // line, and the line before it must be a real message line.
        #expect(text.hasSuffix("\r\n\r\n.\r\n") == false)
        #expect(text.contains("MIME-Version: 1.0"))
    }

    /// 587 end to end, through the submitter rather than the session: the upgrade
    /// happens, and the whole envelope + data phase lands after it.
    @Test("a full STARTTLS submission puts every credential and message byte after the upgrade")
    func explicitTLSSubmission() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptSTARTTLSLogin(transport)
        await SMTPHarness.scriptTransaction(transport)
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.explicitEndpoint)

        let id = await SMTPHarness.expectSuccess { try await submitter.submit(SMTPHarness.message()) }
        #expect(id == "2.0.0 Ok: queued as QUEUEID")

        #expect(await transport.startTLSCount == 1)
        let index = try #require(await transport.upgradeSendIndex)
        let before = await transport.sent.prefix(index).map { String(decoding: $0, as: UTF8.self) }
        // Exact, and non-empty: see `SMTPSessionTLSTests.explicitTLS` for why the
        // non-emptiness is the half that makes this falsifiable.
        #expect(before == ["EHLO [127.0.0.1]\r\n", "STARTTLS\r\n"])
        let plaintext = String(decoding: await transport.bytesSentBeforeUpgrade, as: UTF8.self)
        #expect(plaintext.contains(SMTPHarness.password) == false)
        #expect(plaintext.contains("MAIL FROM") == false)
        #expect(plaintext.contains("Subject 1") == false)
    }
}

@Suite("SMTP submission — at most once")
@MainActor
struct SMTPAtMostOnceTests {
    /// A `250` on end-of-data is the ONLY thing that yields an id.
    @Test("an id is returned only after the 250 on end-of-data")
    func idOnlyAfter250() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await SMTPHarness.scriptTransaction(transport, endOfData: "451 4.3.0 try later\r\n")
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.implicitEndpoint)

        let error = await SMTPHarness.failure { try await submitter.submit(SMTPHarness.message()) }
        // The submitter reports in the vocabulary `Outbox` branches on: a 4xx is
        // the ordinary retryable `.providerFailed`.
        #expect(error as? MailError == .providerFailed(status: 451, message: "4.3.0 try later"))
    }

    /// A `5xx` on end-of-data: the message was explicitly refused, so it is
    /// permanent — not "possibly sent", and not retried five times.
    @Test("a 5xx on end-of-data is permanent")
    func permanentOnEndOfData() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await SMTPHarness.scriptTransaction(transport, endOfData: "552 5.3.4 message too large\r\n")
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.implicitEndpoint)

        let error = await SMTPHarness.failure { try await submitter.submit(SMTPHarness.message()) }
        #expect(error as? MailError == .sendRefused(status: 552, message: "5.3.4 message too large"))
    }

    /// **The exact interleaving.** `DATA` is accepted (`354`), the whole message is
    /// written, and then the server never answers. Whether it was delivered is
    /// unknowable, so it is reported as possibly sent.
    ///
    /// The transport uses `.throwScriptExhausted` deliberately: it models the
    /// server going away *after* the data was written, and it makes the assertion
    /// below — that the full message really did cross the wire — meaningful rather
    /// than a claim about a dialogue that ended earlier.
    @Test("a failure after DATA was accepted is reported as possibly sent")
    func possiblySentAfterData() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue(SMTPHarness.greeting)
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await transport.respond(to: "MAIL FROM", with: "250 2.1.0 sender ok\r\n")
        await transport.respond(to: "RCPT TO", with: "250 2.1.5 recipient ok\r\n", repeatable: true)
        await transport.respond(to: "DATA", with: "354 end with <CRLF>.<CRLF>\r\n")
        // Nothing scripted for the terminator: the next read finds an empty script.
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.implicitEndpoint)

        let error = await SMTPHarness.failure { try await submitter.submit(SMTPHarness.message()) }
        #expect(error as? MailError == .sendOutcomeUnknown(
            message: "the message data was fully written but the server never answered"))
        // The data really was transmitted — that is what makes this "possibly
        // sent" rather than "failed".
        let text = try #require(await SMTPHarness.transmittedData(transport))
        #expect(text.contains("MIME-Version: 1.0"))
    }

    /// The **write side** of the same danger zone: `DATA` was accepted (`354`) and
    /// then the connection died with **zero bytes of the message written**.
    ///
    /// That is still `possibly sent`, and deliberately so. `SMTPSession.finishData`
    /// cannot know how much of its one `send` reached the peer — the transport seam
    /// expresses "the whole `Data` or an error", and a real socket's error can
    /// arrive after the kernel has already put bytes on the wire. So the safe
    /// direction is taken: hold for a human rather than risk a duplicate. This test
    /// pins that choice, and pins that the data genuinely did not go out — the
    /// contrast with `possiblySentAfterData`, where it did.
    @Test("a write failure with nothing transmitted is still reported as possibly sent")
    func possiblySentWhenTheWriteItselfFailed() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await SMTPHarness.scriptTransaction(transport)
        // The message write fails outright, recording nothing.
        await transport.failSend(containing: "MIME-Version: 1.0")
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.implicitEndpoint)

        let error = await SMTPHarness.failure { try await submitter.submit(SMTPHarness.message()) }
        #expect(error as? MailError == .sendOutcomeUnknown(
            message: "the connection failed while the message data was being written"))
        // Nothing of the message reached the wire — the distinct half of this case.
        #expect(await SMTPHarness.transmittedData(transport) == nil)
        #expect(await transport.sentText.contains("MIME-Version") == false)
        #expect(await transport.sentText.contains("Subject 1") == false)
        // The dialogue really did get past `DATA` first, so this is the post-354
        // branch and not an earlier failure wearing the same error.
        #expect(await transport.sentText.contains("DATA\r\n"))
    }

    /// The other half of the criterion, driven through a **real `Outbox`** with a
    /// **real `SMTPSubmitter`** behind it: the entry is not retried, and not
    /// reported as sent either.
    ///
    /// The provider's `send` is the submitter's, so the interleaving above is what
    /// actually happens inside the drain — this is not a fake error handed to the
    /// outbox.
    /// The second drain is given a **second, fully-scripted transport** that would
    /// happily accept a retransmission. That is what makes the wire assertion
    /// falsifiable: reusing the first (exhausted) transport, a retry dies at the
    /// greeting before `SMTPSession` writes a byte, so an unchanged `sent` would
    /// hold whether the outbox refused to retry or retried and was refused at the
    /// door. A transport that *could* have taken the message and received nothing
    /// is the observation worth having.
    @Test("the outbox holds a possibly-sent entry for review and never auto-retries it")
    func outboxDoesNotRetryPossiblySent() async throws {
        let transport = ScriptedTransport()
        await transport.enqueue(SMTPHarness.greeting)
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await transport.respond(to: "MAIL FROM", with: "250 2.1.0 sender ok\r\n")
        await transport.respond(to: "RCPT TO", with: "250 2.1.5 recipient ok\r\n", repeatable: true)
        await transport.respond(to: "DATA", with: "354 end with <CRLF>.<CRLF>\r\n")
        // The retry's transport: a complete, successful 465 dialogue.
        let second = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(second)
        await SMTPHarness.scriptTransaction(second)
        let (submitter, queue) = SMTPHarness.submitter([transport, second],
                                                       endpoint: SMTPHarness.implicitEndpoint)

        let provider = FakeMailProvider(accountID: "a1")
        provider.sendVia = { message in try await submitter.submit(message) }
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let id = try outbox.enqueue(.send(SMTPHarness.message()), accountID: "a1")

        await SMTPHarness.drain(outbox)

        #expect(outbox.outcome(for: id) == .needsReview)
        #expect(outbox.needsReview().map(\.id) == [id])
        #expect(outbox.pending().isEmpty, "a possibly-sent entry must not be eligible again")
        // Attempts stay at zero: this is not a failure that earns a retry, it is an
        // outcome nobody knows.
        #expect(outbox.needsReview().first?.attempts == 0)

        // A second drain must not touch it. Asserted on what reached the wire: the
        // waiting transport would have completed a submission, and whole-collection
        // equality on `sent` pins that not one byte — no `MAIL FROM`, no `DATA`,
        // nothing at all — was written to it.
        await SMTPHarness.drain(outbox)
        #expect(await second.sent.map { String(decoding: $0, as: UTF8.self) } == [],
                "a second drain retransmitted a possibly-sent message")
        // And the retry never even got as far as opening that connection.
        #expect(queue.handedOut == 1)
        #expect(outbox.outcome(for: id) == .needsReview)
        outbox.teardownWake()
    }

    /// The contrast that keeps the test above honest: an ordinary transient
    /// failure IS retried. Without this, "held for review" could be the outbox
    /// refusing to retry anything at all.
    @Test("a transient failure is still retried, and a permanent one is dead-lettered at once")
    func retryContrast() async throws {
        let retryable = FakeMailProvider(accountID: "a1")
        retryable.failures["send"] = [MailError.providerFailed(status: 451, message: "try later")]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: retryable,
                            accountID: "a1")
        let id = try outbox.enqueue(.send(SMTPHarness.message()), accountID: "a1")
        await SMTPHarness.drain(outbox)
        #expect(outbox.outcome(for: id) == .queued(inFlight: false))
        #expect(outbox.pending().map(\.id) == [id])
        // Second drain: the scripted failure is exhausted, so it transmits.
        await SMTPHarness.drain(outbox)
        #expect(outbox.outcome(for: id) == .sent)
        outbox.teardownWake()

        let refused = FakeMailProvider(accountID: "a1")
        refused.failures["send"] = [MailError.sendRefused(status: 550, message: "no such user")]
        let second = Outbox(documents: InMemoryDocumentStore(), provider: refused, accountID: "a1")
        let refusedID = try second.enqueue(.send(SMTPHarness.message()), accountID: "a1")
        await SMTPHarness.drain(second)
        if case .deadLettered(let last) = second.outcome(for: refusedID) {
            #expect(last?.contains("550") == true)
        } else {
            Issue.record("a permanent refusal must dead-letter on the first failure, not after five")
        }
        #expect(second.deadLettered().map(\.id) == [refusedID])
        #expect(second.deadLettered().first?.attempts == 0)
        #expect(second.pending().isEmpty)
        second.teardownWake()
    }

    /// A successful submission through the outbox: the entry leaves, and it leaves
    /// as `.sent` — recorded, not inferred from its absence.
    @Test("a 250 on end-of-data is what makes the outbox report sent")
    func successIsRecorded() async throws {
        let transport = await SMTPHarness.transport()
        try await SMTPHarness.scriptImplicitTLSLogin(transport)
        await SMTPHarness.scriptTransaction(transport)
        let submitter = SMTPHarness.submitter(transport, endpoint: SMTPHarness.implicitEndpoint)
        let provider = FakeMailProvider(accountID: "a1")
        provider.sendVia = { try await submitter.submit($0) }
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider, accountID: "a1")
        let id = try outbox.enqueue(.send(SMTPHarness.message()), accountID: "a1")

        await SMTPHarness.drain(outbox)

        #expect(outbox.outcome(for: id) == .sent)
        #expect(outbox.pending().isEmpty)
        #expect(outbox.needsReview().isEmpty)
        outbox.teardownWake()
    }
}
