import Foundation

/// Intercepts every request made through a session configured with this
/// protocol registered, and answers from an in-process handler — no live
/// network call is ever made. Used to exercise `GmailProvider` against
/// recorded fixture bytes and synthetic status codes (404, 429, …).
final class StubURLProtocol: URLProtocol {
    /// Set once per test right before constructing the `URLSession`; reset
    /// after, since this state is process-global (a `URLProtocol` subclass
    /// has no per-session instance state of its own to hang it on).
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
