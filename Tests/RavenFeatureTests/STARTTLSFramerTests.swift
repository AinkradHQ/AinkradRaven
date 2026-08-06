import Testing
import Foundation
@testable import RavenFeature

/// The framer that lets an explicit-TLS mail port work on a real `NWConnection`.
///
/// ## What these tests can and cannot prove
///
/// They run against a **real socket** (`LoopbackTCPServer`), which is the point:
/// `STARTTLSFramer` is a negotiation with `Network.framework` about when TLS may
/// start, and a scripted double cannot disagree with the framework. What they
/// prove is therefore the half that is falsifiable without a certificate:
///
///  * the plaintext prelude really does flow, in both directions, on a connection
///    that has **never reached `.ready`** — i.e. `.willMarkReady` holds TLS off
///    and the framer's own I/O path works. This is the half whose failure mode is
///    a hang, so it is the half worth a socket;
///  * a failed upgrade fails the transport, and leaves nothing usable behind.
///
/// What they do **not** prove: that a successful TLS handshake follows
/// `markReady()` against a real mail server. That needs a server with a
/// certificate, and it is Task 24's first checklist item. Nothing here should be
/// read as covering it.
///
/// Every await is bounded (`boundedOutcome`, ~2s). A framer bug presents as a hung
/// handshake, and a hung suite is reported as an infrastructure timeout and
/// retried rather than as the bug it is.
@Suite("STARTTLS on a real socket")
struct STARTTLSFramerTests {

    /// The prelude, on a socket, before any upgrade.
    ///
    /// Falsifiable in the exact way that matters: if `start` returned `.ready`
    /// instead of `.willMarkReady`, TLS above would put a ClientHello on the wire
    /// immediately and `server.receivedText` would not be the two clean lines
    /// pinned below — and if the framer's input path were wrong, the reads would
    /// never resolve and the deadline would record an Issue.
    @Test("the plaintext prelude runs on a socket that has not reached .ready")
    func plaintextPreludeRunsBeforeTheUpgrade() async throws {
        let server = try LoopbackTCPServer(
            greeting: "* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n",
            rules: [.init(needle: "A1 STARTTLS", reply: "A1 OK begin TLS\r\n")])
        try await server.start()
        defer { server.stop() }

        let transport = NetworkTransport(
            endpoint: MailTransportEndpoint(host: "127.0.0.1", port: server.port, tls: .explicit),
            connectTimeout: .seconds(2), readTimeout: .seconds(2))
        defer { Task { await transport.close() } }

        let transcript = await boundedOutcome { () async throws -> String in
            try await transport.connect()
            let greeting = try await transport.read()
            try await transport.send(Data("A1 STARTTLS\r\n".utf8))
            let ok = try await transport.read()
            return String(decoding: greeting + ok, as: UTF8.self)
        }
        guard case .success(let text)? = transcript else {
            Issue.record("the plaintext prelude did not complete: \(String(describing: transcript))")
            return
        }
        #expect(text == "* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\nA1 OK begin TLS\r\n")
        // The server's side of the same claim: exactly the prelude, and nothing a
        // TLS handshake would have added.
        #expect(server.receivedText == "A1 STARTTLS\r\n")
    }

    /// The one property that cannot be traded away.
    ///
    /// The server has no certificate at all, so the handshake cannot succeed. What
    /// is asserted is not merely that `startTLS()` throws — it is that **nothing
    /// works afterwards**: a build with any fallback path would leave `send`/`read`
    /// working on the plaintext socket, which is the shape a credential leak would
    /// take.
    ///
    /// **What kills this test.** Removing `hardFail` from the handshake deadline,
    /// and a framer that answers `.ready`. It does NOT cover the window *during*
    /// an in-flight handshake — `hardFail` fires at the deadline, i.e. after any
    /// write racing it. That window is
    /// `aWriteRacingTheHandshakeNeverReachesTheServer`, below, and it is where the
    /// `didRequestUpgrade` / `Control.write` guards are falsified.
    @Test("a failed upgrade fails the transport and never continues in the clear")
    func failedUpgradeLeavesNothingUsable() async throws {
        // The server answers `220 go ahead` and then says nothing ever again — the
        // *stall*, which is this task's characteristic failure mode and the reason
        // `startTLS()` carries its own deadline. Two shapes were tried; this one
        // was kept because the alternative was not deterministic:
        //
        //   * peer hangs up on the ClientHello — `NWConnection` did NOT report the
        //     failure within two seconds, so the test recorded a deadline Issue
        //     rather than a clean failure. A closed peer mid-handshake is simply
        //     not promptly surfaced, which is itself the argument for the deadline.
        //   * peer stalls (this one) — `startTLS()`'s deadline fires, `hardFail`
        //     cancels the connection, and everything after it is dead.
        let server = try LoopbackTCPServer(
            greeting: "220 mail.test ESMTP\r\n",
            rules: [.init(needle: "STARTTLS", reply: "220 go ahead\r\n")])
        try await server.start()
        defer { server.stop() }

        let transport = NetworkTransport(
            endpoint: MailTransportEndpoint(host: "127.0.0.1", port: server.port, tls: .explicit),
            connectTimeout: .milliseconds(300), readTimeout: .milliseconds(300))
        defer { Task { await transport.close() } }

        let upgrade = await boundedOutcome { () async throws -> String in
            try await transport.connect()
            _ = try await transport.read()
            try await transport.send(Data("STARTTLS\r\n".utf8))
            _ = try await transport.read()
            try await transport.startTLS()
            return "upgraded"
        }
        switch upgrade {
        case .success:
            Issue.record("the upgrade reported success against a server with no TLS at all")
        case .failure(let error):
            #expect(error as? MailTransportError
                    == .tlsFailed("the TLS handshake did not complete in time"))
        case nil:
            return  // the deadline already recorded an Issue
        }

        // The half that actually rules out a fallback.
        let afterSend = await boundedOutcome {
            try await transport.send(Data("AUTH PLAIN AGFAYi5jAHNlY3JldA==\r\n".utf8))
        }
        if case .success = afterSend {
            Issue.record("a write succeeded after the upgrade failed — that is the plaintext fallback")
        }
        let afterRead = await boundedOutcome { try await transport.read() }
        if case .success(let data) = afterRead {
            Issue.record("a read succeeded after the upgrade failed: \(data.count) bytes")
        }
        // And no credential-shaped byte ever reached the server.
        #expect(server.receivedText.contains("AUTH PLAIN") == false)
    }

    /// The credential-leak shape, in the one window that is not covered by the
    /// transport being dead: a write issued **while the handshake is in flight**.
    ///
    /// `hardFail` cannot help here — it fires at the handshake deadline, which is
    /// *after* the racing write. So this is what falsifies the two guards that
    /// exist for exactly this window: `NetworkTransport.usesPlaintextPath`'s
    /// `didRequestUpgrade` term, and `STARTTLSFramer.Control.write`'s refusal.
    /// Removing both puts `AUTH PLAIN …` on a real socket, and the assertion below
    /// reads it back off the server. No certificate is needed, because the leak
    /// happens before any handshake could have completed.
    ///
    /// **The send is deliberately not awaited under a deadline.** `send()` has no
    /// deadline of its own and parks on `connection.send` until `hardFail`, so a
    /// bounded await around it would report the *clean* build as a hang. The claim
    /// here is about what reached the server, not about what the call returned —
    /// so the wire is what is asserted, and the task's result is collected
    /// afterwards only to keep the test from outliving it.
    @Test("a write racing the in-flight handshake never reaches the server")
    func aWriteRacingTheHandshakeNeverReachesTheServer() async throws {
        // Stalls after `220 go ahead`, so the handshake stays genuinely in flight
        // for as long as this test needs to write into it.
        let server = try LoopbackTCPServer(
            greeting: "220 mail.test ESMTP\r\n",
            rules: [.init(needle: "STARTTLS", reply: "220 go ahead\r\n")])
        try await server.start()
        defer { server.stop() }

        let transport = NetworkTransport(
            endpoint: MailTransportEndpoint(host: "127.0.0.1", port: server.port, tls: .explicit),
            connectTimeout: .milliseconds(800), readTimeout: .milliseconds(300))
        defer { Task { await transport.close() } }

        let prelude = await boundedOutcome { () async throws -> String in
            try await transport.connect()
            _ = try await transport.read()
            try await transport.send(Data("STARTTLS\r\n".utf8))
            return String(decoding: try await transport.read(), as: UTF8.self)
        }
        guard case .success(let go)? = prelude else {
            Issue.record("the prelude did not complete: \(String(describing: prelude))")
            return
        }
        #expect(go == "220 go ahead\r\n")

        let upgrade = Task { try await transport.startTLS() }
        try await Task.sleep(for: .milliseconds(200))
        // 200ms in: the handshake is in flight and cannot have finished — the
        // server has no certificate and has said nothing since the `220`.
        let racingWrite = Task {
            try await transport.send(Data("AUTH PLAIN AGFAYi5jAHNlY3JldA==\r\n".utf8))
        }
        try await Task.sleep(for: .milliseconds(200))

        // The assertion. Not "the call failed" — "the bytes are not on the server".
        #expect(server.receivedText.contains("AUTH PLAIN") == false)
        // Non-vacuous: this socket really did carry the prelude, so an empty
        // `receivedText` cannot be what makes the line above pass.
        #expect(server.receivedText.contains("STARTTLS"))

        _ = await boundedOutcome { _ = await upgrade.result }
        _ = await boundedOutcome { _ = await racingWrite.result }
    }

    /// The typed case the acceptance criteria let survive, with the one meaning it
    /// still has: not "Raven cannot do STARTTLS" but "this endpoint was not built
    /// for an upgrade". An implicit endpoint is already encrypted and has no
    /// framer to release; answering "fine" would be a lie a caller could not
    /// detect. No socket is involved, so this is exact.
    @Test("an implicit endpoint still refuses an upgrade, typed")
    func implicitEndpointRefusesAnUpgrade() async throws {
        let transport = NetworkTransport(
            endpoint: MailTransportEndpoint(host: "127.0.0.1", port: 993, tls: .implicit))
        let outcome = await boundedOutcome { try await transport.startTLS() }
        guard case .failure(let error)? = outcome else {
            Issue.record("expected tlsUpgradeUnsupported, got \(String(describing: outcome))")
            return
        }
        #expect(error as? MailTransportError == .tlsUpgradeUnsupported)
    }
}
