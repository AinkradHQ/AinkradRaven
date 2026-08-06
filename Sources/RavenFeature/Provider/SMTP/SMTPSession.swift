import Foundation

/// The SMTP submission dialogue over one `MailTransport`: greeting, `EHLO`,
/// `STARTTLS`, SASL `AUTH`, `MAIL FROM`/`RCPT TO`/`DATA`, `QUIT`.
///
/// ## Why this is far simpler than `IMAPSession`
///
/// SMTP submission is strictly lock-step: one command, one reply, no tags, no
/// pipelining (RFC 2920's `PIPELINING` is deliberately not used — it buys one
/// round trip on a path that runs once per sent message, and costs the ability
/// to attribute a failure to the exact command that caused it). So there is no
/// in-flight table, no continuation routing, and no leaked-continuation class of
/// bug to defend against: every `await` here is a call this actor's own caller is
/// suspended on.
///
/// ## The two TLS modes
///
/// - **Implicit (465).** TLS is part of `connect()`; the transport is encrypted
///   from the first byte and `isEncrypted` is true before the greeting.
/// - **Explicit (587).** Connect in plaintext, `EHLO`, `STARTTLS`, upgrade, then
///   `EHLO` again. Driven end-to-end in `SMTPSessionTests` against
///   `ScriptedTransport`, and on a real socket by `STARTTLSFramer` (Task 15b),
///   which holds TLS inert below the plaintext prelude and releases it here.
///   Nothing in this file changed for that: `upgradeToTLS()` asks the transport
///   and believes its answer. `SMTPSessionError.tlsUpgradeUnsupported` remains for
///   a transport that genuinely cannot upgrade — a typed, specific failure, never
///   a silent fallback to plaintext.
///
/// ## What is never written
///
/// A credential is written only from `authenticate(_:)`, only after
/// `isEncrypted` is true, and it is never stored on this actor, never logged and
/// never placed in an error. `SMTPSessionError`'s cases carry codes, mechanism
/// names and server text only.
actor SMTPSession {
    private let transport: any MailTransport
    private let security: MailTransportTLS
    /// What `EHLO` announces us as. A domain literal is what RFC 5321 asks for;
    /// submission servers do not check it, and it must not leak anything about the
    /// machine, so it is a fixed constant rather than the real hostname.
    private let clientDomain: String

    /// Bytes read but not yet consumed as a line. A real socket splits anywhere,
    /// including mid-CRLF, so a reply is assembled from this buffer rather than
    /// from whatever one `read()` happened to return.
    private var buffer = Data()
    private var didGreet = false
    private var isClosed = false

    /// Whether the connection is encrypted right now. The one gate on writing a
    /// credential.
    private(set) var isEncrypted: Bool
    /// `EHLO` keywords, uppercased, e.g. `STARTTLS`, `SIZE`, `AUTH`, `8BITMIME`.
    /// Reset and re-learned after a successful upgrade, as RFC 3207 §4.2 requires.
    private(set) var extensions: Set<String> = []
    /// The mechanisms named on the `AUTH` line, uppercased.
    private(set) var authMechanisms: Set<String> = []
    /// Every command line written, in order, without its CRLF. Assertable, and
    /// deliberately never used for logging — see `SMTPSessionTests`, which pins
    /// that no credential-bearing line is recorded verbatim here.
    private(set) var issuedVerbs: [String] = []

    init(transport: any MailTransport,
         security: MailTransportTLS,
         clientDomain: String = "[127.0.0.1]") {
        self.transport = transport
        self.security = security
        self.clientDomain = clientDomain
        self.isEncrypted = security == .implicit
    }

    // MARK: - Opening

    /// Connects, reads the `220` greeting, and sends the first `EHLO`.
    ///
    /// Nothing is written before the greeting is read: SMTP is a server-speaks-first
    /// protocol and a client that writes early desynchronises servers that answer
    /// `554` on connect.
    func connect() async throws {
        try await transport.connect()
        let greeting = try await readReply()
        try expect(greeting, 220)
        didGreet = true
        try await ehlo()
    }

    /// `EHLO`, and the extension list it answers with. `HELO` is not attempted as
    /// a fallback: a server with no `EHLO` has no `STARTTLS` and no `AUTH`, so
    /// there is no way to submit through it safely, and quietly falling back would
    /// mean quietly sending a password in the clear.
    func ehlo() async throws {
        let reply = try await command("EHLO \(clientDomain)")
        try expect(reply, 250)
        learnExtensions(from: reply)
    }

    /// Negotiates `STARTTLS` and upgrades the transport.
    ///
    /// The order is load-bearing and asserted: `STARTTLS` is refused outright
    /// unless the server advertised it, the upgrade happens before any `AUTH`
    /// byte exists, and everything learned in plaintext is thrown away
    /// afterwards. That last part is not tidiness — RFC 3207 §4.2 requires the
    /// client to discard the cached `EHLO` response, because a plaintext
    /// `250-AUTH …` line could have been written by anyone on the path.
    func upgradeToTLS() async throws {
        guard extensions.contains("STARTTLS") else { throw SMTPSessionError.startTLSUnadvertised }
        let reply = try await command("STARTTLS")
        try expect(reply, 220)
        do {
            try await transport.startTLS()
        } catch MailTransportError.tlsUpgradeUnsupported {
            throw SMTPSessionError.tlsUpgradeUnsupported
        }
        isEncrypted = true
        // Anything already buffered was received in plaintext and must not be
        // parsed as part of the encrypted session.
        buffer.removeAll()
        extensions.removeAll()
        authMechanisms.removeAll()
        try await ehlo()
    }

    // MARK: - Authentication

    /// SASL over SMTP's framing (RFC 4954). The payloads are `SASLMechanism`'s —
    /// the same bytes `IMAPAuthenticator` sends — with `AUTH <mech> <base64>` in
    /// place of IMAP's `AUTHENTICATE`.
    ///
    /// Refused before the first byte if the connection is not encrypted. That is
    /// the structural reason no `AUTH` byte can precede a `STARTTLS` upgrade: it
    /// is not a matter of call order in `SMTPSubmitter` but of this guard, which
    /// only `upgradeToTLS()` (or implicit TLS) can satisfy.
    func authenticate(_ credential: IMAPCredential) async throws {
        guard isEncrypted else { throw SMTPSessionError.notEncrypted }
        switch credential {
        case .xoauth2(let username, let accessToken):
            guard authMechanisms.contains("XOAUTH2") else {
                throw SMTPSessionError.mechanismUnavailable("XOAUTH2")
            }
            let payload = SASLMechanism.base64(
                SASLMechanism.xoauth2InitialResponse(username: username,
                                                     accessToken: accessToken))
            let reply = try await command("AUTH XOAUTH2 \(payload)", redactedAs: "AUTH XOAUTH2")
            if reply.code == 334 {
                // XOAUTH2 reports failure as a *challenge* carrying base64 JSON,
                // not as a final code. The exchange is half-open until the client
                // acknowledges with an empty line, and only then does the server
                // send its real refusal. Same shape as `IMAPAuth`'s
                // `answersFailureChallenge`.
                let refusal = try await command("", redactedAs: "<SASL ack>")
                throw SMTPSessionError.authenticationRefused(code: refusal.code,
                                                             text: refusal.text)
            }
            try expectAuthenticated(reply)
        case .appPassword(let username, let password):
            if authMechanisms.contains("PLAIN") {
                let payload = SASLMechanism.base64(
                    SASLMechanism.plainInitialResponse(username: username, password: password))
                let reply = try await command("AUTH PLAIN \(payload)", redactedAs: "AUTH PLAIN")
                try expectAuthenticated(reply)
            } else if authMechanisms.contains("LOGIN") {
                try await authenticateLogin(username: username, password: password)
            } else {
                throw SMTPSessionError.mechanismUnavailable("PLAIN")
            }
        }
    }

    /// `AUTH LOGIN`: two base64 challenges, username then password. Not a
    /// standardised mechanism but the only one some submission servers offer, and
    /// it is tried only when `PLAIN` is absent.
    private func authenticateLogin(username: String, password: String) async throws {
        let start = try await command("AUTH LOGIN")
        guard start.code == 334 else { try expectAuthenticated(start); return }
        let user = try await command(SASLMechanism.base64(Data(username.utf8)),
                                    redactedAs: "<AUTH LOGIN username>")
        guard user.code == 334 else { try expectAuthenticated(user); return }
        let reply = try await command(SASLMechanism.base64(Data(password.utf8)),
                                     redactedAs: "<AUTH LOGIN password>")
        try expectAuthenticated(reply)
    }

    /// `235` is the only success. Anything else is a refusal, reported as
    /// permanent so the outbox does not spend five attempts on a wrong password.
    private func expectAuthenticated(_ reply: SMTPReply) throws {
        guard reply.code == 235 else {
            throw SMTPSessionError.authenticationRefused(code: reply.code, text: reply.text)
        }
    }

    // MARK: - Transaction

    /// `MAIL FROM:<sender>`. The angle brackets are part of the syntax, and an
    /// empty reverse path (`<>`) is legal — so the address is inserted, never
    /// trimmed or defaulted.
    func mailFrom(_ address: String) async throws {
        let reply = try await command("MAIL FROM:<\(address)>")
        try expect(reply, 250)
    }

    /// `RCPT TO:<address>`, one per recipient. `251` ("will forward") is accepted
    /// alongside `250`: it is a success, and treating it as a failure would fail a
    /// send that the server has agreed to deliver.
    func rcptTo(_ address: String) async throws {
        let reply = try await command("RCPT TO:<\(address)>")
        guard reply.code == 250 || reply.code == 251 else { throw classify(reply) }
    }

    /// `DATA`, expecting `354`. Split from `finishData` because everything after
    /// this reply is in the at-most-once danger zone: from here on, a failure
    /// cannot be assumed to mean "nothing was sent".
    func beginData() async throws {
        let reply = try await command("DATA")
        guard reply.code == 354 else { throw classify(reply) }
    }

    /// Writes an already dot-stuffed, already CRLF-terminated payload followed by
    /// the end-of-data sequence, and returns the server's verdict.
    ///
    /// **This is where at-most-once is decided.** Three outcomes, deliberately
    /// distinct:
    /// - `250` → the server has taken responsibility for the message. Returned,
    ///   and only then may a caller report a send.
    /// - a well-formed `4yz`/`5yz` → the server explicitly refused the message. It
    ///   was NOT accepted, so this is an ordinary retryable/permanent failure.
    /// - anything else — the connection breaking, a read timing out, a reply that
    ///   does not parse — → `outcomeUnknown`. The bytes went out and no verdict
    ///   came back, so whether the message was queued is unknowable from here.
    ///   Reporting it as a normal failure would let the outbox retry and deliver
    ///   the same email twice; that is exactly the trade `Outbox` documents, and
    ///   it is resolved the same way: hold for a human, never resend.
    ///
    /// - Parameter payload: the message, dot-stuffed by
    ///   `SMTPSubmitter.dotStuffed`, ending in CRLF. The terminating `.CRLF` is
    ///   appended here so no caller can forget it.
    @discardableResult
    func finishData(_ payload: Data) async throws -> SMTPReply {
        // One write, payload and terminator together: it keeps the recorded byte
        // stream assertable as a whole (`…CRLF.CRLF` is the tail of one chunk
        // rather than a boundary between two) and a partial write is not a case
        // this transport seam can express anyway — `send` either delivers the
        // whole `Data` or throws.
        do {
            try await transport.send(payload + Data(".\r\n".utf8))
        } catch {
            throw SMTPSessionError.outcomeUnknown(
                "the connection failed while the message data was being written")
        }
        let reply: SMTPReply
        do {
            reply = try await readReply()
        } catch {
            throw SMTPSessionError.outcomeUnknown(
                "the message data was fully written but the server never answered")
        }
        if reply.code == 250 { return reply }
        throw classify(reply)
    }

    /// Best effort, and deliberately non-throwing: a `QUIT` that fails changes
    /// nothing about what did or did not get sent, and letting it throw would
    /// replace an accurate outcome with a misleading one. Always closes the
    /// transport.
    func quit() async {
        if !isClosed, didGreet {
            try? await transport.send(Data("QUIT\r\n".utf8))
            issuedVerbs.append("QUIT")
        }
        isClosed = true
        await transport.close()
    }

    // MARK: - Wire

    /// Writes one command line and reads its complete reply.
    ///
    /// - Parameter redactedAs: what to record in `issuedVerbs` instead of the
    ///   line itself. Every credential-bearing command passes one; the recorded
    ///   list is therefore safe to print in a test failure, and there is no
    ///   in-memory copy of a SASL payload for anything else to find.
    @discardableResult
    private func command(_ line: String, redactedAs redacted: String? = nil) async throws
        -> SMTPReply {
        issuedVerbs.append(redacted ?? line)
        try await transport.send(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    /// Reads lines until one is final, then assembles them.
    private func readReply() async throws -> SMTPReply {
        var lines: [SMTPReplyParser.Line] = []
        while true {
            let line = try SMTPReplyParser.parseLine(try await readLine())
            lines.append(line)
            if !line.isContinuation { return try SMTPReplyParser.assemble(lines) }
            guard lines.count <= SMTPReplyParser.maximumLines else {
                throw SMTPSessionError.malformedReply(
                    "a reply with more than \(SMTPReplyParser.maximumLines) continuation lines")
            }
        }
    }

    /// One CRLF-terminated line, assembled across however many reads it takes. A
    /// bare LF is NOT accepted as a terminator: tolerating it would let a lone LF
    /// inside a reply split it into two, and the resulting code mismatch is
    /// caught by `assemble` only because this stays strict.
    private func readLine() async throws -> String {
        let crlf = Data([0x0D, 0x0A])
        while true {
            if let range = buffer.range(of: crlf) {
                let line = Data(buffer[buffer.startIndex..<range.lowerBound])
                buffer = Data(buffer[range.upperBound...])
                guard let text = String(data: line, encoding: .utf8) else {
                    throw SMTPSessionError.malformedReply("a reply line that is not UTF-8")
                }
                return text
            }
            buffer.append(try await transport.read())
        }
    }

    /// `EHLO`'s first line is the greeting text; each line after it is one
    /// extension. `AUTH` carries its mechanisms on the same line, either
    /// space- or (on some old servers) `=`-separated.
    private func learnExtensions(from reply: SMTPReply) {
        for line in reply.lines.dropFirst() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "=" })
                .map { $0.uppercased() }
            guard let keyword = fields.first else { continue }
            extensions.insert(keyword)
            if keyword == "AUTH" { authMechanisms.formUnion(fields.dropFirst()) }
        }
    }

    private func expect(_ reply: SMTPReply, _ code: Int) throws {
        guard reply.code == code else { throw classify(reply) }
    }

    /// Turns a reply we cannot proceed on into the right kind of error: 4yz
    /// retryable, 5yz permanent, anything else (a `3yz` where a completion
    /// belonged, say) an unexpected reply — which is permanent, because a
    /// dialogue this far out of step will not right itself on a retry.
    private func classify(_ reply: SMTPReply) -> SMTPSessionError {
        if reply.isTransient { return .transientFailure(code: reply.code, text: reply.text) }
        if reply.isPermanent { return .permanentFailure(code: reply.code, text: reply.text) }
        return .unexpectedReply(code: reply.code, text: reply.text)
    }
}
