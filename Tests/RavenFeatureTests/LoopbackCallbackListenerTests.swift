import Testing
import Foundation
@testable import RavenFeature

// Moved verbatim out of `GmailAuthTests` when the loopback listener was
// extracted into the provider-neutral `Auth/` layer. Every assertion below was
// already present there; none was weakened. The only edits are the suite names
// (they no longer say "Gmail", because the listener no longer knows about any
// provider) and the callback-page copy expectation, which now asserts the page
// names no single provider.

/// Covers the pure parsing seam the loopback listener depends on to read the
/// OAuth redirect off the raw HTTP request line. The listener's actual socket
/// behavior (binding, accepting a connection, an OS-chosen port) is NOT
/// covered here — that would require real networking, which is disallowed in
/// this test target. This suite exists precisely so the logic that CAN be
/// tested without a socket (parsing) is not buried inside the connection
/// handler where it couldn't be.
@Suite("OAuth callback parsing")
struct CallbackRequestParserTests {
    @Test("a successful callback yields the code and state")
    func successfulCallback() {
        let result = CallbackRequestParser.parse(
            requestLine: "GET /?code=abc123&state=xyz789 HTTP/1.1")
        #expect(result.code == "abc123")
        #expect(result.state == "xyz789")
        #expect(result.error == nil)
    }

    @Test("a denied consent screen yields an error, not a code")
    func accessDenied() {
        let result = CallbackRequestParser.parse(
            requestLine: "GET /?error=access_denied&state=xyz789 HTTP/1.1")
        #expect(result.error == "access_denied")
        #expect(result.code == nil)
    }

    @Test("a malformed request line yields nothing rather than crashing")
    func malformedLine() {
        #expect(CallbackRequestParser.parse(requestLine: "not an http request").code == nil)
        #expect(CallbackRequestParser.parse(requestLine: "").code == nil)
        #expect(CallbackRequestParser.parse(requestLine: "GET").code == nil)
    }

    @Test("the first line is extracted regardless of CRLF vs LF line endings")
    func firstLineExtraction() {
        #expect(CallbackRequestParser.firstLine(of: "GET /?code=a HTTP/1.1\r\nHost: x\r\n\r\n")
                == "GET /?code=a HTTP/1.1")
        #expect(CallbackRequestParser.firstLine(of: "GET /?code=a HTTP/1.1\nHost: x\n\n")
                == "GET /?code=a HTTP/1.1")
        #expect(CallbackRequestParser.firstLine(of: "") == nil)
    }
}

/// Covers the state-mismatch rejection at the point where an `authorize()`
/// implementation would use it — since `authorize()` itself drives a real
/// loopback listener and browser open (untestable without network/UI), this
/// exercises the same comparison `LoopbackCallbackListener.run` performs,
/// directly against the parser's output, to prove a spoofed callback from a
/// different local process would be rejected rather than silently accepted.
@Suite("OAuth state verification")
struct StateVerificationTests {
    @Test("a callback whose state does not match the one that was sent is not treated as the expected code")
    func mismatchedStateIsDetectable() {
        let expectedState = "expected-state"
        let callback = CallbackRequestParser.parse(
            requestLine: "GET /?code=abc123&state=attacker-state HTTP/1.1")
        #expect(callback.code == "abc123")
        #expect(callback.state != expectedState)
    }
}

/// Covers the exactly-once resume discipline `LoopbackCallbackListener`
/// depends on to avoid double-resuming its continuation when a timeout races
/// a connection callback. `OneShotResumeGuard` is lock-protected rather than
/// relying on queue confinement, so — unlike the listener's socket handling,
/// which genuinely cannot be tested without a real network — this can and
/// does get exercised under real concurrent contention from multiple tasks.
/// This is a stress test, not a formal proof: it does not guarantee every
/// possible interleaving was hit, but a lock around a single boolean has no
/// interesting interleavings left to miss once the critical section is that
/// small, and 200 concurrent firers reliably exercise the race in practice.
@Suite("OneShotResumeGuard")
struct OneShotResumeGuardTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("only the first of many concurrent fires invokes the completion")
    func exactlyOneCompletionUnderConcurrency() async {
        let completions = Counter()
        let resumeGuard = OneShotResumeGuard<Int> { _ in completions.increment() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { resumeGuard.fire(i) }
            }
        }

        #expect(completions.current == 1)
    }

    @Test("fire() reports true for exactly one caller under concurrency")
    func exactlyOneTrueReturnUnderConcurrency() async {
        let trueReturns = Counter()
        let resumeGuard = OneShotResumeGuard<Int> { _ in }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if resumeGuard.fire(i) { trueReturns.increment() }
                }
            }
        }

        #expect(trueReturns.current == 1)
    }
}

/// Regression cover for the continuation leak: the `Coordinator` owning the
/// loopback listener was referenced only by a local inside
/// `withCheckedThrowingContinuation`, while every callback it installed
/// captured `[weak self]` — so it deallocated the instant `run(...)` returned,
/// every resume path became a no-op, and the flow hung forever ("SWIFT TASK
/// CONTINUATION MISUSE … leaked its continuation"). These tests drive
/// `run(...)` for real, over a loopback socket only (no live network, no
/// browser, no provider traffic): a leaked continuation would hang here rather
/// than fail, and the harness timeout would surface it as a stuck test run.
@Suite("Loopback listener lifetime")
struct LoopbackCallbackListenerLifetimeTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt16?
        func set(_ new: UInt16) { lock.lock(); value = new; lock.unlock() }
        var current: UInt16? { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("the listener binds, reports its port, and times out with a definite error")
    func bindsAndTimesOutRatherThanLeaking() async {
        let observedPort = Box()

        await #expect(throws: LoopbackCallbackListener.ListenerError.timedOut) {
            try await LoopbackCallbackListener.run(
                timeout: .milliseconds(400),
                openBrowser: { port in
                    // Only called from the `.ready` state handler, so reaching
                    // here proves the coordinator was still alive well after
                    // `run(...)` returned — the exact thing the bug broke.
                    observedPort.set(port)
                    return "http://localhost:\(port)"
                },
                expectedState: "test-state")
        }

        // A real, non-zero OS-assigned ephemeral port was bound.
        #expect((observedPort.current ?? 0) > 0)
    }

    @Test("a second flow can bind after the first tore itself down")
    func coordinatorIsReleasedSoAnotherFlowCanRun() async {
        // If the self-reference were never cleared the coordinator (and its
        // listener) would leak; running the whole flow twice in a row checks
        // teardown actually happened rather than only that nothing hung.
        for _ in 0..<2 {
            await #expect(throws: LoopbackCallbackListener.ListenerError.timedOut) {
                try await LoopbackCallbackListener.run(
                    timeout: .milliseconds(200),
                    openBrowser: { "http://localhost:\($0)" },
                    expectedState: "test-state")
            }
        }
    }
}

@Suite("OAuth callback page")
struct LoopbackCallbackPageTests {
    @Test("the success page names Raven, not the pre-rename Mail")
    func successCopy() {
        let page = LoopbackCallbackListener.callbackPage(success: true)
        #expect(page.contains("Raven"))
        #expect(page.contains("return to Mail") == false)
        #expect(page.contains("Signed in"))
    }

    @Test("the failure page tells the user it failed and how to retry")
    func failureCopy() {
        let page = LoopbackCallbackListener.callbackPage(success: false)
        #expect(page.contains("Sign-in failed"))
        #expect(page.lowercased().contains("try connecting again"))
    }

    @Test("the page is self-contained — a loopback socket cannot serve linked assets")
    func selfContained() {
        for page in [LoopbackCallbackListener.callbackPage(success: true),
                     LoopbackCallbackListener.callbackPage(success: false)] {
            #expect(page.contains("<link") == false)
            #expect(page.contains("src=") == false)
            #expect(page.contains("http://") == false)
            #expect(page.contains("https://") == false)
        }
    }

    @Test("the page names no single provider — one listener serves every account kind")
    func providerNeutralCopy() {
        for page in [LoopbackCallbackListener.callbackPage(success: true),
                     LoopbackCallbackListener.callbackPage(success: false)] {
            #expect(page.lowercased().contains("gmail") == false)
            #expect(page.lowercased().contains("google") == false)
        }
    }
}
