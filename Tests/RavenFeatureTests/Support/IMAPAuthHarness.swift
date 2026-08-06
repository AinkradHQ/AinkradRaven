import Testing
import Foundation
@testable import RavenFeature

// Shared fixtures and the connected-session factory for the `IMAPAuth*` suites.
//
// Split out of `IMAPAuthTests.swift` to keep every file inside the repo's
// 500-line limit, the same way `IMAPSessionHarness` was split out of
// `IMAPSessionTests.swift`. Both `IMAPAuthTests` and `IMAPAuthChannelTests` use
// these, which is the other reason they cannot stay file-private in either.

/// The credentials every IMAP auth test uses. Distinctive strings, so "does this
/// byte stream contain the password" is an unambiguous question rather than a
/// substring coincidence.
enum Fixture {
    static let address = "a@example.test"
    static let password = "app-password-secret"
    static let accessToken = "access-token-secret"
    static let refreshToken = "refresh-token-secret"

    /// A greeting that publishes `capabilities` in a `[CAPABILITY …]` response
    /// code — the common real case, and the reason authentication normally costs
    /// no `CAPABILITY` round trip. It also means a test that asserts "nothing was
    /// written" is meaningful: nothing legitimately needs writing before the
    /// credential command.
    static func greeting(_ capabilities: String) -> String {
        "* OK [CAPABILITY \(capabilities)] ready\r\n"
    }
}

/// A connected session plus its greeting, over a scripted transport.
///
/// Idle reads always `.suspend`, i.e. behave like a socket. `.throwScriptExhausted`
/// is deliberately NOT used, even by the tests that assert *nothing* was sent: it
/// tears the session down immediately after the greeting, so a regression that DID
/// write a credential never gets that far and the test passes for the wrong
/// reason. Every "nothing was written" test therefore scripts a response that
/// would let the forbidden command SUCCEED, and asserts on the recorded bytes.
/// Both of those choices were forced by mutation runs.
func makeAuthSession(
    capabilities: String
) async throws -> (IMAPSession, ScriptedTransport, IMAPGreeting) {
    let transport = ScriptedTransport(idleReads: .suspend)
    await transport.enqueue(Fixture.greeting(capabilities))
    let session = IMAPSession(transport: transport)
    let greeting = try await session.connect()
    return (session, transport, greeting)
}

// MARK: - Deadlines
//
// EVERY await on a network-shaped operation in the IMAP auth suites goes through
// one of the helpers below. None of them may be called bare.
//
// The reason is the bug class this whole stack exists to prevent: a continuation
// nobody resumes presents as a HANG, and a hung suite reports as an
// infrastructure timeout that gets retried, not as the bug it is. The gate proved
// this twice on this task — a mutation that consumed a reactive SASL line without
// sending it wedged the run with no `Test run with` line at all, because two
// `authenticate` calls were still bare inside `#expect(throws:)`. A bounded wait
// turns that into a named failing expectation in two seconds.

/// Runs `body` with a ~2s deadline. Nil means it never finished, and an `Issue` is
/// already recorded describing that as the leaked-continuation shape.
func boundedOutcome<T: Sendable>(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> T
) async -> Result<T, any Error>? {
    let box = BoundedOutcomeBox<T>()
    let task = Task {
        do { await box.set(.success(try await body())) }
        catch { await box.set(.failure(error)) }
    }
    for _ in 0..<200 {
        if let value = await box.value { return value }
        try? await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    Issue.record("an operation never resolved within 2s — the leaked-continuation shape",
                 sourceLocation: sourceLocation)
    return nil
}

/// Asserts `body` threw exactly `expected`, within the deadline.
func expectAuthFailure<T: Sendable>(
    _ expected: IMAPAuthError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> T
) async {
    guard let outcome = await boundedOutcome(sourceLocation: sourceLocation, body) else { return }
    switch outcome {
    case .success(let value):
        Issue.record("expected \(expected) but it succeeded: \(value)",
                     sourceLocation: sourceLocation)
    case .failure(let error):
        #expect(error as? IMAPAuthError == expected, sourceLocation: sourceLocation)
    }
}

/// Asserts `body` failed somehow within the deadline, and returns the error for
/// further inspection (used by the credential-leak assertions).
func authFailure<T: Sendable>(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> T
) async -> (any Error)? {
    guard let outcome = await boundedOutcome(sourceLocation: sourceLocation, body) else { return nil }
    switch outcome {
    case .success(let value):
        Issue.record("expected a failure but it succeeded: \(value)",
                     sourceLocation: sourceLocation)
        return nil
    case .failure(let error):
        return error
    }
}

/// Asserts `body` SUCCEEDED within the deadline, and returns its value. Success
/// paths are bounded for the same reason failures are: a routing bug that answers
/// the wrong waiter leaves the right one suspended.
func expectAuthSuccess<T: Sendable>(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> T
) async -> T? {
    guard let outcome = await boundedOutcome(sourceLocation: sourceLocation, body) else { return nil }
    switch outcome {
    case .success(let value): return value
    case .failure(let error):
        Issue.record("expected success but it failed: \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

private actor BoundedOutcomeBox<T: Sendable> {
    private(set) var value: Result<T, any Error>?
    func set(_ value: Result<T, any Error>) {
        if self.value == nil { self.value = value }
    }
}
