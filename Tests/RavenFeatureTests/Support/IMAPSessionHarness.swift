import Testing
import Foundation
@testable import RavenFeature

/// The harness for `IMAPSessionTests`, split out of it to keep both files inside
/// the repo's 500-line limit.
///
/// Every wait here is **bounded** and records an `Issue` when it expires. That is
/// not politeness: the bug class Task 8's session exists to prevent is a
/// continuation nobody resumes, which manifests as a hang. A hung suite is
/// reported as an infrastructure timeout and gets retried; a failed expectation
/// is reported as the bug it is. Both of these were verified by mutation — see
/// the task report.
enum IMAPSessionHarness {

    static let greetingLine = "* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] ready\r\n"

    /// A connected session whose transport suspends idle reads, i.e. behaves like
    /// a socket: the read loop parks between responses instead of erroring.
    static func makeSession(
        greeting: String = IMAPSessionHarness.greetingLine,
        chunkPlan: ScriptedTransport.ChunkPlan = .whole
    ) async throws -> (IMAPSession, ScriptedTransport) {
        let transport = ScriptedTransport(chunkPlan: chunkPlan, idleReads: .suspend)
        await transport.enqueue(greeting)
        let session = IMAPSession(transport: transport)
        try await session.connect()
        return (session, transport)
    }

    /// Runs `execute` in its own task so several commands can be in flight at
    /// once. The task is started immediately; the caller synchronises on
    /// `waitForInFlight`.
    static func issue(_ session: IMAPSession,
                       _ command: IMAPCommand) -> Task<IMAPTaggedResponse, any Error> {
        Task { try await session.execute(command) }
    }

    /// Bounded wait: `#expect` fails instead of spinning forever if the count is
    /// never reached, so a routing bug shows up as a failure, not a hung suite.
    @discardableResult
    static func waitForInFlight(_ session: IMAPSession, _ count: Int,
                                 sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        for _ in 0..<10_000 {
            if await session.inFlightCount >= count { return true }
            await Task.yield()
        }
        let actual = await session.inFlightCount
        Issue.record("in-flight count never reached \(count) (stuck at \(actual))",
                     sourceLocation: sourceLocation)
        return false
    }

    /// Collects a command's outcome **with a deadline**, so a waiter that never
    /// resumes fails this test in ~2s instead of hanging the suite. That matters
    /// more here than anywhere else in the repo: the defect this file guards
    /// against (a continuation nobody resumes) presents as a hang, and a hung
    /// suite reports as an infrastructure timeout rather than as a bug. Verified
    /// by deleting `failAllWaiters` from `IMAPSession.close()`: with it deleted
    /// these tests FAIL here; without this helper they hung the whole run.
    static func outcome(of task: Task<IMAPTaggedResponse, any Error>,
                         sourceLocation: SourceLocation = #_sourceLocation) async
        -> Result<IMAPTaggedResponse, any Error>? {
        let box = OutcomeBox()
        Task {
            do { await box.set(.success(try await task.value)) }
            catch { await box.set(.failure(error)) }
        }
        for _ in 0..<200 {
            if let value = await box.value { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("a command never resolved within 2s — the leaked-continuation shape",
                     sourceLocation: sourceLocation)
        return nil
    }

    /// Asserts a command resolved with exactly `expected`, within the deadline.
    static func expectFailure(_ task: Task<IMAPTaggedResponse, any Error>,
                               _ expected: IMAPSessionError,
                               sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let outcome = await outcome(of: task, sourceLocation: sourceLocation) else { return }
        switch outcome {
        case .success(let response):
            Issue.record("expected \(expected) but the command succeeded: \(response)",
                         sourceLocation: sourceLocation)
        case .failure(let error):
            #expect(error as? IMAPSessionError == expected, sourceLocation: sourceLocation)
        }
    }

    /// Asserts a command SUCCEEDED within the deadline, and returns it. Success
    /// paths are deadline-bounded for the same reason failures are: a routing bug
    /// that sends a response to the wrong waiter leaves the right one suspended.
    static func expectSuccess(_ task: Task<IMAPTaggedResponse, any Error>,
                               sourceLocation: SourceLocation = #_sourceLocation) async
        -> IMAPTaggedResponse? {
        guard let outcome = await outcome(of: task, sourceLocation: sourceLocation) else { return nil }
        switch outcome {
        case .success(let response): return response
        case .failure(let error):
            Issue.record("expected success but the command failed: \(error)",
                         sourceLocation: sourceLocation)
            return nil
        }
    }

    /// Asserts a command failed somehow, within the deadline.
    static func expectAnyFailure(_ task: Task<IMAPTaggedResponse, any Error>,
                                  sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let outcome = await outcome(of: task, sourceLocation: sourceLocation) else { return }
        if case .success(let response) = outcome {
            Issue.record("expected a failure but the command succeeded: \(response)",
                         sourceLocation: sourceLocation)
        }
    }

    private actor OutcomeBox {
        private(set) var value: Result<IMAPTaggedResponse, any Error>?
        func set(_ value: Result<IMAPTaggedResponse, any Error>) {
            if self.value == nil { self.value = value }
        }
    }

    /// Bounded wait until the transport has recorded `count` writes.
    static func waitForSent(_ transport: ScriptedTransport, _ count: Int,
                             sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<10_000 {
            if await transport.sent.count >= count { return }
            await Task.yield()
        }
        Issue.record("only \(await transport.sent.count) of \(count) writes reached the transport",
                     sourceLocation: sourceLocation)
    }

    static func waitForSuspendedRead(_ transport: ScriptedTransport,
                                      sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<10_000 {
            if await transport.suspendedReadCount > 0 { return }
            await Task.yield()
        }
        Issue.record("the read loop never parked on an idle read", sourceLocation: sourceLocation)
    }


}
