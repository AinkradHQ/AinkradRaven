import Testing
import Foundation
@testable import RavenFeature


/// The invariant Task 8 built and Task 9 nearly broke: `continuationOrder` is an
/// EXACT FIFO of tags that are guaranteed a `+ `, so a continuation request is
/// never attributed to the wrong command.
///
/// `AUTHENTICATE` is the first command whose continuations are *conditional*. The
/// first implementation of it declared the SASL ack as an ordinary wire chunk,
/// which registered the tag in `continuationOrder` for a `+ ` the server usually
/// never sends. These tests reproduce the resulting desync and pin the structural
/// fix (`IMAPCommand.isExclusive` + `reactiveContinuationLines`).
@Suite("IMAP channel exclusivity")
struct IMAPChannelExclusivityTests {

    /// The gate's scenario, verbatim. On the pre-fix code the recorded wire was:
    ///
    /// ```
    /// ["A0001 AUTHENTICATE XOAUTH2 dXNlcj1hQGIudGVzdAFhdXRoPUJlYXJlciBUT0sBAQ==\r\n",
    ///  "A0002 LOGIN \"a@b.test\" {14}\r\n",
    ///  "\r\n"]
    /// ```
    ///
    /// The server's `+ ready for literal` was consumed by AUTHENTICATE's
    /// speculative CRLF, the literal payload was never written, and the server
    /// read that CRLF as the first 2 of 14 literal octets. Unrecoverable.
    @Test("AUTHENTICATE cannot be pipelined with a literal command that would steal its continuation")
    func exclusiveCommandRefusesPipelining() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 AUTH=XOAUTH2 SASL-IR")
        defer { Task { await session.close() } }
        _ = greeting
        // No scripted answer: AUTHENTICATE stays in flight, exactly as it would
        // while the server thinks about the credential.
        let authenticate = IMAPSessionHarness.issue(session, IMAPAuthenticator.xoauth2Command(
            username: Fixture.address, accessToken: Fixture.accessToken, saslIR: true))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))

        // A synchronising literal — the command whose `+ ready for literal` used
        // to be stolen.
        //
        // Issued through the DEADLINE-BOUNDED harness, not a bare `try await`. If
        // the refusal is ever lost, this LOGIN is admitted, writes `{14}` and then
        // waits forever for a literal continuation nobody scripted — a hang, which
        // reports as an infrastructure timeout rather than as the bug it is. The
        // first mutation run of this test hung the whole suite for exactly that
        // reason.
        let login = IMAPCommand("LOGIN", [.text("a@b.test"),
                                          .literal(Data("secret-literal".utf8))])
        await IMAPSessionHarness.expectFailure(
            IMAPSessionHarness.issue(session, login),
            .channelReserved(exclusiveTag: "A0001"))

        // The proof is the recorded wire: the LOGIN never reached the transport, so
        // there is no `{14}` awaiting a continuation that AUTHENTICATE could steal,
        // and no stray CRLF write.
        let sent = await transport.sent
        #expect(sent.count == 1)
        #expect(await transport.sentText.contains("LOGIN") == false)
        #expect(await transport.sentText.contains("{14}") == false)
        #expect(sent.contains(Data("\r\n".utf8)) == false)
        // And the exclusive command is still cleanly in flight, not collaterally
        // damaged by the refusal.
        #expect(await session.inFlightCount == 1)
        // `continuationOrder` stayed EXACT: AUTHENTICATE declared no literal, so it
        // is not awaiting a continuation even though it can answer one.
        #expect(await session.pendingContinuationTags.isEmpty)

        await session.close()
        await IMAPSessionHarness.expectFailure(authenticate, .closed)
        #expect(await session.inFlightCount == 0)
    }

    @Test("AUTHENTICATE refuses to start while other commands are in flight")
    func exclusiveCommandNeedsAnIdleChannel() async throws {
        let (session, transport, _) = try await makeAuthSession(capabilities: "IMAP4rev1 AUTH=PLAIN")
        defer { Task { await session.close() } }
        let noop = IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))

        // Deadline-bounded for the same reason as the test above.
        await IMAPSessionHarness.expectFailure(
            IMAPSessionHarness.issue(session, IMAPAuthenticator.plainCommand(
                username: Fixture.address, password: Fixture.password, saslIR: true)),
            .channelReserved(exclusiveTag: nil))
        // Refused BEFORE the write, so the credential is not on the wire at all.
        #expect(await transport.sentText.contains(Fixture.password) == false)
        #expect(await transport.sentText.contains("AUTHENTICATE") == false)
        #expect(await session.inFlightCount == 1)

        await session.close()
        await IMAPSessionHarness.expectFailure(noop, .closed)
        #expect(await session.inFlightCount == 0)
    }

    /// Cancellation is the one path that is not a teardown, so Task 8's "every
    /// teardown path fails every waiter" did not cover it: a cancelled caller left
    /// its record in `inFlight` forever. That stranded one command before Task 9.
    /// Once `requireChannelAdmits` started reading `inFlight`, a stranded
    /// *exclusive* record refused every later command — the whole channel bricked
    /// by one cancelled task. Before the fix this test reported
    /// `inFlight=1` and `channelReserved(exclusiveTag: Optional("A0001"))` for a
    /// plain `NOOP`.
    ///
    /// This is a fix to Task 8 behaviour that Task 9 made load-bearing, not a
    /// Task 9-only concern.
    @Test("cancelling an exclusive command releases the channel instead of bricking it")
    func cancellationReleasesTheReservation() async throws {
        let (session, transport, _) = try await makeAuthSession(
            capabilities: "IMAP4rev1 AUTH=XOAUTH2 SASL-IR")
        defer { Task { await session.close() } }
        // Tag-specific rules: a repeatable one would answer A0003 with A0002's tag,
        // which the session would (correctly) treat as an unknown-tag protocol error.
        await transport.respond(to: "A0002 NOOP", with: "A0002 OK NOOP completed\r\n")
        await transport.respond(to: "A0003 NOOP", with: "A0003 OK NOOP completed\r\n")

        // In flight with no answer scripted, exactly as it would be while the
        // server thinks about the credential.
        let authenticate = IMAPSessionHarness.issue(session, IMAPAuthenticator.xoauth2Command(
            username: Fixture.address, accessToken: Fixture.accessToken, saslIR: true))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))

        authenticate.cancel()
        // The cancelled caller is resolved, not left suspended.
        await IMAPSessionHarness.expectAnyFailure(authenticate)
        for _ in 0..<10_000 {
            if await session.inFlightCount == 0 { break }
            await Task.yield()
        }
        #expect(await session.inFlightCount == 0)
        #expect(await session.pendingContinuationTags.isEmpty)

        // The reservation is released: an ordinary command now succeeds. This is
        // the assertion that fails on the pre-fix code.
        let noop = try #require(await IMAPSessionHarness.expectSuccess(
            IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))))
        #expect(noop.status == .ok)
        #expect(await session.isRunning)

        // And the server's late completion for the abandoned tag does NOT tear the
        // connection down: IMAP cannot withdraw an issued command, so that answer
        // is expected and is swallowed exactly once.
        await transport.enqueue("A0001 NO Invalid credentials\r\n")
        await IMAPSessionHarness.waitForSuspendedRead(transport)
        #expect(await session.isRunning)
        let second = try #require(await IMAPSessionHarness.expectSuccess(
            IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))))
        #expect(second.status == .ok)
        #expect(await session.abandonedTagCount == 0)   // drained by the completion

        // A tag the server never answers would otherwise sit in `abandonedTags` for
        // the whole session, since the set only drains on a completion. `close()`
        // prunes it: nothing can arrive after that.
        let orphan = IMAPSessionHarness.issue(session, IMAPAuthenticator.xoauth2Command(
            username: Fixture.address, accessToken: Fixture.accessToken, saslIR: true))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        orphan.cancel()
        await IMAPSessionHarness.expectAnyFailure(orphan)
        for _ in 0..<10_000 {
            if await session.abandonedTagCount == 1 { break }
            await Task.yield()
        }
        #expect(await session.abandonedTagCount == 1)
        await session.close()
        #expect(await session.abandonedTagCount == 0)
    }

    /// The other side of `abandonedTags`: it swallows a cancelled command's
    /// completion EXACTLY ONCE, so the tag does not become a permanent licence to
    /// accept unknown completions.
    ///
    /// Untested until now — changing `abandonedTags.remove(tag) != nil` to
    /// `.contains(tag)` (swallow forever) left the suite green.
    @Test("an abandoned tag's completion is swallowed exactly once, not forever")
    func abandonedTagIsSwallowedOnce() async throws {
        let (session, transport, _) = try await makeAuthSession(
            capabilities: "IMAP4rev1 AUTH=XOAUTH2 SASL-IR")
        defer { Task { await session.close() } }
        await transport.respond(to: "A0002 NOOP", with: "A0002 OK NOOP completed\r\n")

        let authenticate = IMAPSessionHarness.issue(session, IMAPAuthenticator.xoauth2Command(
            username: Fixture.address, accessToken: Fixture.accessToken, saslIR: true))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        authenticate.cancel()
        await IMAPSessionHarness.expectAnyFailure(authenticate)

        // First completion for the abandoned tag: expected, swallowed, session lives.
        await transport.enqueue("A0001 NO Invalid credentials\r\n")
        let noop = try #require(await IMAPSessionHarness.expectSuccess(
            IMAPSessionHarness.issue(session, IMAPCommand("NOOP"))))
        #expect(noop.status == .ok)
        #expect(await session.isRunning)

        // SECOND completion for the same tag: the licence is spent, so this is now
        // an unknown tag and tears the connection down rather than being accepted.
        // A server sending it is either broken or being spoofed; either way the
        // stream is no longer interpretable.
        await transport.enqueue("A0001 NO Invalid credentials\r\n")
        for _ in 0..<10_000 {
            if await session.isRunning == false { break }
            await Task.yield()
        }
        #expect(await session.isRunning == false)
        #expect(await session.inFlightCount == 0)
    }

    /// Cancelling a command that has written `{n}` but not the octets is the one
    /// case that cannot be made clean: the server is waiting for bytes nobody will
    /// write and IMAP cannot withdraw the count, so the stream is desynchronised.
    /// `abandon` tears down and says so, rather than leaving a half-written command
    /// wedging a connection other callers share.
    ///
    /// Untested until now — deleting the whole `continuationOrder.contains(tag)`
    /// branch left the suite green.
    @Test("cancelling a command with an unwritten literal tears the connection down")
    func cancellingAnUnwrittenLiteralTearsDown() async throws {
        let (session, transport, _) = try await makeAuthSession(capabilities: "IMAP4rev1")
        defer { Task { await session.close() } }

        // A synchronising literal: chunk 0 ends with `{14}` and the payload waits
        // for a `+ ` that this test never scripts.
        let login = IMAPSessionHarness.issue(session, IMAPCommand(
            "LOGIN", [.text("a@b.test"), .literal(Data("secret-literal".utf8))]))
        #expect(await IMAPSessionHarness.waitForInFlight(session, 1))
        #expect(await session.pendingContinuationTags == ["A0001"])
        #expect(await transport.sentText.hasSuffix("{14}\r\n"))

        login.cancel()
        await IMAPSessionHarness.expectFailure(login, .protocolError(
            "command A0001 cancelled with an unwritten literal; the stream cannot be resynchronised"))

        // Torn down, not merely unreserved: the payload can never be written, so
        // every later command on this connection would be read as literal octets.
        for _ in 0..<10_000 {
            if await session.isRunning == false { break }
            await Task.yield()
        }
        #expect(await session.isRunning == false)
        #expect(await session.inFlightCount == 0)
        #expect(await transport.isClosed)
        // The literal payload never reached the wire.
        #expect(await transport.sentText.contains("secret-literal") == false)
    }

    @Test("a reactive SASL ack is written only when the server actually asks for it")
    func reactiveAckIsNotSpeculative() async throws {
        let (session, transport, greeting) = try await makeAuthSession(
            capabilities: "IMAP4rev1 AUTH=XOAUTH2")   // no SASL-IR
        defer { Task { await session.close() } }
        // Without SASL-IR the FIRST `+` is certain and carries the credential; the
        // SECOND is the failure challenge. Both are reactive lines, in order.
        await transport.respond(to: "AUTHENTICATE XOAUTH2", with: "+ \r\n")
        await transport.respond(to: "dXNlcj1h", with: "+ eyJzdGF0dXMiOiI0MDEifQ==\r\n")
        await transport.respond(to: "\r\n", with: "A0001 NO Invalid credentials\r\n")

        let auth = IMAPAuthenticator(session: session, security: .implicit)
        await expectAuthFailure(IMAPAuthError.rejected("Invalid credentials")) {
            try await auth.authenticate(
                .xoauth2(username: Fixture.address, accessToken: Fixture.accessToken),
                greeting: greeting)
        }
        // Compared as a WHOLE ARRAY, deliberately. The previous version asserted
        // `count == 3` and then indexed `sent[0…2]`; `#expect` does not stop the
        // test, so a wrong count reached the subscript and trapped on an
        // out-of-range index. That cost the named diagnosis (the process died
        // before reporting it) and, worse, made xcodebuild relaunch the bundle —
        // after which the summary totals are a sum across launches, which silently
        // voids any declared-equals-executed check made against that run. One
        // comparison, no subscripts, no trap.
        //
        // The wording here avoids quoting the trap and relaunch banners verbatim,
        // so that grepping a run's log for those banners cannot match this comment.
        #expect(await transport.sent == [
            Data("A0001 AUTHENTICATE XOAUTH2\r\n".utf8),
            Data("dXNlcj1hQGV4YW1wbGUudGVzdAFhdXRoPUJlYXJlciBhY2Nlc3MtdG9rZW4tc2VjcmV0AQE=\r\n".utf8),
            Data("\r\n".utf8),
        ])
        // NOTE: no `pendingContinuationTags.isEmpty` assertion here. It used to be,
        // with a comment claiming the tag was "never registered as an expected
        // continuation at any point" — but this runs AFTER the command settled, and
        // `settle` already ran `continuationOrder.removeAll { $0 == tag }`, so it is
        // empty for every possible implementation. It was proven vacuous: the
        // reactive-lines-as-chunks mutation failed three other assertions and left
        // this one green. The exactness claim is asserted where it is falsifiable —
        // `exclusiveCommandRefusesPipelining`, while the command is still in flight.
    }
}

@Suite("IMAP credentials never leak")
struct IMAPCredentialLeakTests {

    @Test("a rejected login's error carries the server's text and no credential")
    func rejectionCarriesNoCredential() async throws {
        let (session, transport, greeting) = try await makeAuthSession(capabilities: "IMAP4rev1")
        defer { Task { await session.close() } }
        await transport.respond(to: "LOGIN", with: "A0001 NO [AUTHENTICATIONFAILED] bad\r\n")

        let auth = IMAPAuthenticator(session: session, security: .implicit)
        // Deadline-bounded: the scripted `NO` only arrives in response to the
        // client's write, so a client that never writes would hang here.
        let captured = await authFailure {
            try await auth.authenticate(
                .appPassword(username: Fixture.address, password: Fixture.password),
                greeting: greeting)
        }

        let error = try #require(captured)
        #expect(error as? IMAPAuthError == .rejected("[AUTHENTICATIONFAILED] bad"))
        // Every string form an error could reach a log through.
        for rendered in [String(describing: error), String(reflecting: error),
                         (error as? IMAPAuthError).map { "\($0)" } ?? ""] {
            #expect(rendered.contains(Fixture.password) == false, "\(rendered)")
        }
    }

    @Test("a command's description redacts the password and the SASL response")
    func descriptionRedacts() throws {
        let login = IMAPAuthenticator.loginCommand(
            username: Fixture.address, password: Fixture.password)
        #expect(login.description == "LOGIN \"a@example.test\" <redacted>")
        #expect(login.description.contains(Fixture.password) == false)

        let xoauth2 = IMAPAuthenticator.xoauth2Command(
            username: Fixture.address, accessToken: Fixture.accessToken, saslIR: true)
        #expect(xoauth2.description == "AUTHENTICATE XOAUTH2 <redacted>")
        let encoded = IMAPAuthenticator.base64(IMAPAuthenticator.xoauth2InitialResponse(
            username: Fixture.address, accessToken: Fixture.accessToken))
        // Base64 is not encryption: the encoded form is the credential too.
        #expect(xoauth2.description.contains(encoded) == false)
        #expect(xoauth2.description.contains(Fixture.accessToken) == false)

        // Redaction is a rendering concern only — the wire bytes are unchanged.
        #expect(String(decoding: login.wirePlan(tag: "A1", allowNonSynchronizingLiterals: false)
            .chunks[0], as: UTF8.self).contains(Fixture.password))
    }

    @Test("a credential's only string form names the mechanism, never the secret")
    func credentialRedactedDescription() {
        let password = IMAPCredential.appPassword(
            username: Fixture.address, password: Fixture.password)
        #expect(password.redactedDescription == "app-password(a@example.test)")
        let token = IMAPCredential.xoauth2(
            username: Fixture.address, accessToken: Fixture.accessToken)
        #expect(token.redactedDescription == "xoauth2(a@example.test)")
        #expect(token.redactedDescription.contains(Fixture.accessToken) == false)
    }

    /// The tripwire: if the authentication path ever gains a document-store or
    /// secret-store dependency, this fails and whoever added it has to justify it
    /// here. Source-text assertion in the style of
    /// `OAuthTokenStorageTests.authLayerCannotReachDocuments`, comments stripped
    /// first because these files SHOULD discuss the invariant in prose.
    @Test("the IMAP auth path has no store dependency to leak a credential through")
    func authPathCannotReachStores() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RavenFeatureTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
        func code(of path: String) throws -> String {
            let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            return source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
        }
        for path in ["Sources/RavenFeature/Provider/IMAP/IMAPAuth.swift",
                     "Sources/RavenFeature/Provider/IMAP/IMAPCredential.swift",
                     "Sources/RavenFeature/Provider/IMAP/IMAPSession.swift",
                     "Sources/RavenFeature/Provider/IMAP/IMAPCommand.swift"] {
            let source = try code(of: path)
            #expect(source.contains("PluginDocumentStore") == false,
                    "\(path) must not reach a document store — credentials live in secrets only")
            #expect(source.contains("host.documents") == false, "\(path)")
        }
        // Stronger for the authenticator itself: it holds no secret store either,
        // and knows no key name. Credentials arrive as values.
        let authSource = try code(of: "Sources/RavenFeature/Provider/IMAP/IMAPAuth.swift")
        #expect(authSource.contains("PluginSecretStore") == false)
        #expect(authSource.contains("secret(forKey") == false)
    }
}

@Suite("IMAP credential storage")
@MainActor
struct IMAPCredentialStorageTests {

    @Test("the app password comes from host.secrets and nothing else is stored beside it")
    func appPasswordFromSecrets() throws {
        let secrets = InMemorySecretStore()
        #expect(IMAPAppPasswordStore.credential(
            accountID: Fixture.address, username: Fixture.address, secrets: secrets) == nil)

        IMAPAppPasswordStore.store(Fixture.password, accountID: Fixture.address, secrets: secrets)
        let credential = try #require(IMAPAppPasswordStore.credential(
            accountID: Fixture.address, username: Fixture.address, secrets: secrets))
        guard case .appPassword(let username, let password) = credential else {
            Issue.record("expected an app-password credential")
            return
        }
        #expect(username == Fixture.address)
        #expect(password == Fixture.password)

        // EXHAUSTIVE: one key, the password, and nothing that got cached beside it.
        #expect(secrets.allSecrets() == ["imap-app-password-a@example.test": Fixture.password])

        IMAPAppPasswordStore.clear(accountID: Fixture.address, secrets: secrets)
        #expect(secrets.allSecrets().isEmpty)
    }

    @Test("an empty stored password is treated as absent rather than attempted")
    func emptyPasswordIsAbsent() {
        let secrets = InMemorySecretStore()
        IMAPAppPasswordStore.store("", accountID: Fixture.address, secrets: secrets)
        #expect(IMAPAppPasswordStore.credential(
            accountID: Fixture.address, username: Fixture.address, secrets: secrets) == nil)
    }

    @Test("the refresh token persists in host.secrets and the access token only in memory")
    func oauthTokenSplit() async throws {
        let secrets = InMemorySecretStore()
        StubURLProtocol.handler = { _ in
            (200, [:], Data("""
            {"access_token":"\(Fixture.accessToken)","expires_in":3599}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = OAuthTokenClient(
            configuration: OAuthConfiguration(
                authorizationEndpoint: URL(string: "https://example.test/authorize")!,
                tokenEndpoint: URL(string: "https://example.test/token")!,
                clientID: "cid", clientSecret: nil, scopes: ["imap"]),
            session: StubURLProtocol.makeSession())
        let source = IMAPOAuthCredentialSource(client: client, secrets: secrets)
        source.storeRefreshToken(Fixture.refreshToken, accountID: Fixture.address)

        let credential = try await source.credential(
            accountID: Fixture.address, username: Fixture.address)
        guard case .xoauth2(_, let accessToken) = credential else {
            Issue.record("expected an XOAUTH2 credential")
            return
        }
        #expect(accessToken == Fixture.accessToken)
        // Access token: memory only.
        #expect(source.accessTokens[Fixture.address]?.token == Fixture.accessToken)
        // Refresh token in the Keychain-backed store, and EXHAUSTIVELY nothing
        // else — in particular the access token was not cached beside it.
        #expect(secrets.allSecrets() == ["imap-refresh-a@example.test": Fixture.refreshToken])

        source.signOut(accountID: Fixture.address)
        #expect(secrets.allSecrets().isEmpty)
        #expect(source.accessTokens[Fixture.address] == nil)
    }

    @Test("no refresh token means notAuthenticated, not an empty bearer attempt")
    func missingRefreshToken() async throws {
        let client = OAuthTokenClient(
            configuration: OAuthConfiguration(
                authorizationEndpoint: URL(string: "https://example.test/authorize")!,
                tokenEndpoint: URL(string: "https://example.test/token")!,
                clientID: "cid", clientSecret: nil, scopes: ["imap"]),
            session: StubURLProtocol.makeSession())
        let source = IMAPOAuthCredentialSource(client: client, secrets: InMemorySecretStore())
        await #expect(throws: MailError.notAuthenticated(accountID: Fixture.address)) {
            _ = try await source.credential(
                accountID: Fixture.address, username: Fixture.address)
        }
    }
}
