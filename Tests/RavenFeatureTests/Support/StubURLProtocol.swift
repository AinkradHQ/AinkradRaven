import Foundation
import Testing

/// Intercepts every request made through a session configured with this
/// protocol registered, and answers from an in-process handler — no live
/// network call is ever made. Used to exercise `GmailProvider` against
/// recorded fixture bytes and synthetic status codes (404, 429, …).
final class StubURLProtocol: URLProtocol {
    /// Set once per test right before constructing the `URLSession`; reset
    /// after, since this state is process-global (a `URLProtocol` subclass
    /// has no per-session instance state of its own to hang it on).
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?

    /// Fails a request at the **transport** rather than answering it, when the
    /// closure returns an error for that request.
    ///
    /// Separate from `handler` (which can only express an HTTP status) because a
    /// dropped connection is a genuinely different failure from a 5xx, and the
    /// at-most-once send path treats it as such: the request left and no verdict
    /// came back. Consulted first, so a test can fail exactly one of several
    /// requests and let the handler answer the rest — which is what
    /// `GraphSendTests` needs to fail the *commit* while the draft creation
    /// succeeds. `nil` (the default) leaves every existing test unaffected.
    nonisolated(unsafe) static var transportFailure: (@Sendable (URLRequest) -> Error?)?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failure = StubURLProtocol.transportFailure?(request) {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(
                self,
                didFailWithError:
                    NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serializes every test that drives `StubURLProtocol`, ACROSS suites.
///
/// `handler`/`transportFailure` are process-global, and swift-testing runs
/// suites in parallel, so two suites setting them at once answer each other's
/// requests. `.serialized` would only order tests within one suite; this
/// trait takes one shared lock around each test case of every suite it marks.
/// ponytail: one global lock for all stub tests; per-session routing if the
/// serialized ~100 tests ever make the run measurably slower.
struct StubbedNetworkTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await StubNetworkLock.shared.acquire()
        do {
            try await function()
        } catch {
            await StubNetworkLock.shared.release()
            throw error
        }
        await StubNetworkLock.shared.release()
    }
}

extension Trait where Self == StubbedNetworkTrait {
    static var stubbedNetwork: Self { Self() }
}

private actor StubNetworkLock {
    static let shared = StubNetworkLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock straight to the next waiter, so `held` never drops
    /// between two queued tests.
    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
