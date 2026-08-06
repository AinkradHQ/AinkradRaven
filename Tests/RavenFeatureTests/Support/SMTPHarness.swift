import Testing
import Foundation
@testable import RavenFeature

/// Shared scripting and **deadlines** for the `SMTP*` suites.
///
/// Every await on a network-shaped operation in those suites goes through
/// `smtpOutcome`/`expectSMTP*` here. That is the same rule the IMAP suites
/// follow, for the same reason: the failure this stack can produce is a read that
/// never returns, which presents as a hang, and a hung run is reported as an
/// infrastructure timeout rather than as the bug it is.
enum SMTPHarness {
    /// Distinctive credential strings, so "do these bytes contain the password"
    /// is an unambiguous question rather than a substring coincidence.
    static let address = "a@example.test"
    static let password = "smtp-app-password-secret"
    static let accessToken = "smtp-access-token-secret"

    static let greeting = "220 mail.example.test ESMTP ready\r\n"

    /// A fixture's bytes, byte-for-byte. CRLF-exact (`-text` in `.gitattributes`),
    /// so no newline translation happens on either side of the blob.
    static func fixtureText(_ name: String) throws -> String {
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: name, withExtension: "txt"),
            "fixture \(name).txt is not in the test bundle — run `xcodegen generate`")
        let data = try Data(contentsOf: url)
        return try #require(String(data: data, encoding: .utf8))
    }

    /// A transport carrying only the greeting, with `.suspend` idle reads so it
    /// behaves like a socket: the session parks waiting for a reply it was not
    /// scripted, instead of erroring out and letting a test pass because the
    /// dialogue ended early. Bounded by the deadlines below.
    static func transport() async -> ScriptedTransport {
        let transport = ScriptedTransport(idleReads: .suspend)
        await transport.enqueue(greeting)
        return transport
    }

    /// Scripts the 465 (implicit TLS) dialogue up to and including `AUTH`.
    static func scriptImplicitTLSLogin(_ transport: ScriptedTransport) async throws {
        await transport.respond(to: "EHLO", with: try fixtureText("smtp-ehlo-multiline"))
        await transport.respond(to: "AUTH", with: "235 2.7.0 accepted\r\n")
    }

    /// Scripts the 587 dialogue: a plaintext `EHLO` that advertises `STARTTLS`
    /// and **no `AUTH`**, then — only after the upgrade — an `EHLO` that does
    /// advertise `AUTH`.
    ///
    /// The two fixtures differ deliberately. A session that failed to re-`EHLO`
    /// after the upgrade, or that kept the extensions it learned in plaintext,
    /// cannot authenticate at all here: it would still be holding a list with no
    /// mechanisms in it. So "the upgrade was done properly" is load-bearing for
    /// the test to pass, rather than merely asserted afterwards.
    static func scriptSTARTTLSLogin(_ transport: ScriptedTransport) async throws {
        await transport.respond(to: "EHLO", with: try fixtureText("smtp-ehlo-plaintext"))
        await transport.respond(to: "STARTTLS", with: "220 2.0.0 ready to start TLS\r\n")
        await transport.respond(to: "EHLO", with: try fixtureText("smtp-ehlo-secured"))
        await transport.respond(to: "AUTH", with: "235 2.7.0 accepted\r\n")
    }

    /// Scripts a successful `MAIL FROM`/`RCPT TO`/`DATA`/end-of-data transaction.
    /// `RCPT TO` and `QUIT` are repeatable; the rest fire once, in dialogue order.
    static func scriptTransaction(_ transport: ScriptedTransport,
                                  endOfData: String = "250 2.0.0 Ok: queued as QUEUEID\r\n") async {
        await transport.respond(to: "MAIL FROM", with: "250 2.1.0 sender ok\r\n")
        await transport.respond(to: "RCPT TO", with: "250 2.1.5 recipient ok\r\n", repeatable: true)
        await transport.respond(to: "DATA", with: "354 end with <CRLF>.<CRLF>\r\n")
        await transport.respond(to: "\r\n.\r\n", with: endOfData)
        await transport.respond(to: "QUIT", with: "221 2.0.0 bye\r\n", repeatable: true)
    }

    /// The 465 endpoint used throughout: implicit TLS, so no upgrade is scripted.
    static let implicitEndpoint = MailTransportEndpoint(host: "mail.example.test",
                                                        port: 465, tls: .implicit)
    /// The 587 endpoint: explicit TLS, upgraded mid-dialogue.
    static let explicitEndpoint = MailTransportEndpoint(host: "mail.example.test",
                                                        port: 587, tls: .explicit)

    /// A submitter wired to `transport`, with an app-password credential.
    static func submitter(_ transport: ScriptedTransport,
                          endpoint: MailTransportEndpoint,
                          credential: IMAPCredential = .appPassword(username: address,
                                                                    password: password))
        -> SMTPSubmitter {
        SMTPSubmitter(endpoint: endpoint, sender: address, credential: credential,
                      makeTransport: { _ in transport })
    }

    /// A submitter that opens a **fresh transport per submission**, handing out
    /// `transports` in order.
    ///
    /// Needed because `submitter(_:endpoint:)` above returns the *same* transport
    /// every time, and that makes a whole class of assertion unfalsifiable: once
    /// the first submission has exhausted the script, a second submission dies at
    /// the greeting before `SMTPSession` writes a byte, so "nothing more reached
    /// the wire" holds whether the outbox refused to retry or retried and was
    /// refused at the door. With a second, fully-scripted transport that would
    /// happily accept a retransmission, an empty `sent` on it means exactly one
    /// thing.
    ///
    /// After the list is exhausted the last transport is handed out again, and
    /// `transportsHandedOut` counts every call — so an unexpected third
    /// submission is visible rather than silently aliased.
    static func submitter(_ transports: [ScriptedTransport],
                          endpoint: MailTransportEndpoint,
                          credential: IMAPCredential = .appPassword(username: address,
                                                                    password: password))
        -> (submitter: SMTPSubmitter, queue: TransportQueue) {
        let queue = TransportQueue(transports)
        return (SMTPSubmitter(endpoint: endpoint, sender: address, credential: credential,
                              makeTransport: { _ in queue.next() }),
                queue)
    }

    /// Hands out pre-built transports in order. `makeTransport` is synchronous and
    /// `@Sendable`, so this is a lock rather than an actor.
    final class TransportQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let transports: [ScriptedTransport]
        private var index = 0
        init(_ transports: [ScriptedTransport]) {
            precondition(!transports.isEmpty)
            self.transports = transports
        }
        func next() -> ScriptedTransport {
            lock.lock()
            defer { lock.unlock() }
            let transport = transports[min(index, transports.count - 1)]
            index += 1
            return transport
        }
        var handedOut: Int {
            lock.lock()
            defer { lock.unlock() }
            return index
        }
    }

    /// An ordinary message with one `to`, one `cc` and one `bcc`.
    static func message(bcc: [MailAddress] = [MailAddress(email: "blind@example.test")],
                        bodyText: String = "Body 1") -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "to@example.test")],
                        cc: [MailAddress(email: "cc@example.test")],
                        bcc: bcc,
                        subject: "Subject 1",
                        bodyText: bodyText)
    }

    /// The one send that carried the message data — the chunk ending in the
    /// end-of-data sequence.
    ///
    /// Deliberately not `sent.last`: the last thing written on a successful
    /// submission is `QUIT`, and an assertion on `sent.last` would be asserting
    /// about the wrong chunk entirely (and would still "pass" a `hasSuffix` check
    /// for a session that transmitted nothing).
    static func transmittedData(_ transport: ScriptedTransport) async -> String? {
        await transport.sent
            .map { String(decoding: $0, as: UTF8.self) }
            .last { $0.hasSuffix("\r\n.\r\n") }
    }

    // MARK: - Deadlines

    /// Runs `body` with a ~3s deadline. `nil` means it never finished, and an
    /// `Issue` describing that as the hang shape is already recorded.
    static func outcome<T: Sendable>(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error>? {
        let box = OutcomeBox<T>()
        let task = Task {
            do { await box.set(.success(try await body())) }
            catch { await box.set(.failure(error)) }
        }
        for _ in 0..<300 {
            if let value = await box.value { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        Issue.record("an SMTP operation never resolved within 3s — the hang shape",
                     sourceLocation: sourceLocation)
        return nil
    }

    /// `Outbox.drain()` with a deadline.
    ///
    /// Needed for the same reason every other await here is bounded, and found the
    /// same way: `drain()` does not throw and suspends on the provider, so a
    /// regression that leaves the SMTP dialogue parked hangs the whole run instead
    /// of failing a test. A mutation run (removing the end-of-data terminator, so
    /// the scripted server never answers) wedged the suite here until this helper
    /// existed.
    @MainActor
    static func drain(_ outbox: Outbox,
                      sourceLocation: SourceLocation = #_sourceLocation) async {
        let flag = DrainFlag()
        let task = Task { @MainActor in
            await outbox.drain()
            flag.done = true
        }
        for _ in 0..<300 {
            if flag.done { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        Issue.record("outbox.drain() never returned within 3s — a send parked on the network",
                     sourceLocation: sourceLocation)
    }

    @MainActor private final class DrainFlag { var done = false }

    /// Asserts `body` succeeded within the deadline, and returns its value.
    static func expectSuccess<T: Sendable>(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async throws -> T
    ) async -> T? {
        guard let outcome = await outcome(sourceLocation: sourceLocation, body) else { return nil }
        switch outcome {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("expected success but it failed: \(error)", sourceLocation: sourceLocation)
            return nil
        }
    }

    /// Asserts `body` threw exactly `expected` within the deadline.
    static func expectFailure<T: Sendable>(
        _ expected: SMTPSessionError,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async throws -> T
    ) async {
        guard let outcome = await outcome(sourceLocation: sourceLocation, body) else { return }
        switch outcome {
        case .success(let value):
            Issue.record("expected \(expected) but it succeeded: \(value)",
                         sourceLocation: sourceLocation)
        case .failure(let error):
            #expect(error as? SMTPSessionError == expected, sourceLocation: sourceLocation)
        }
    }

    /// Asserts `body` failed somehow within the deadline, and hands back the error.
    static func failure<T: Sendable>(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async throws -> T
    ) async -> (any Error)? {
        guard let outcome = await outcome(sourceLocation: sourceLocation, body) else { return nil }
        switch outcome {
        case .success(let value):
            Issue.record("expected a failure but it succeeded: \(value)",
                         sourceLocation: sourceLocation)
            return nil
        case .failure(let error): return error
        }
    }

    private actor OutcomeBox<T: Sendable> {
        private(set) var value: Result<T, any Error>?
        func set(_ value: Result<T, any Error>) { if self.value == nil { self.value = value } }
    }
}
