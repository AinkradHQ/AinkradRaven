import Foundation
import Network

// This file was split out of `GmailAuth.swift`, which had grown to 678 lines by
// carrying four independent top-level types. What moved here is the loopback
// redirect capture: the request parser, the listener, its `Coordinator`, and the
// `OneShotResumeGuard` the coordinator resumes through.
//
// The cut is along type boundaries, so no access control changed and no body was
// edited — these were already separate `internal` types that only ever spoke to
// each other and to `GmailAuth` through their own public-to-the-module API.
// `GmailAuth` keeps the credential path (PKCE, the token exchange, the refresh
// token in the Keychain) and calls `LoopbackCallbackListener.run(...)` exactly as
// before.
//
// The resume-exactly-once discipline is deliberately NOT split: `Coordinator`,
// its `selfRetain`, the timeout work item and `OneShotResumeGuard` are all still
// in one file, because that invariant is the thing they collectively enforce and
// it is only reviewable if they can be read together.

// MARK: - Loopback callback capture

/// Parses the OAuth redirect off the first line of a raw HTTP request, e.g.
/// `GET /?code=abc&state=xyz HTTP/1.1`. Pure and free of any networking, so
/// it is unit-testable without a socket.
enum CallbackRequestParser {
    struct Result: Equatable {
        let code: String?
        let error: String?
        let state: String?
    }

    static func parse(requestLine: String) -> Result {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET" else {
            return Result(code: nil, error: nil, state: nil)
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            return Result(code: nil, error: nil, state: nil)
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return Result(code: value("code"), error: value("error"), state: value("state"))
    }

    /// The first line of a raw HTTP request, however the line ending was sent.
    static func firstLine(of rawRequest: String) -> String? {
        rawRequest.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }).first.map(String.init)
    }
}

/// Binds a one-shot loopback HTTP listener on an OS-chosen port, opens the
/// authorization URL in the browser once the port is known, and resolves with
/// the `code` from the first request the listener receives — tearing itself
/// down exactly once on every path (success, denial, malformed request, or
/// timeout).
///
/// This type has never been exercised against real Google traffic — see the
/// task report. Its socket-handling is deliberately not unit-tested (that
/// would require real networking); the parsing it depends on
/// (`CallbackRequestParser`) is pure and is tested directly instead.
enum LoopbackCallbackListener {
    enum ListenerError: Error, Equatable {
        case portUnavailable
        case authorizationDenied(String)
        case malformedCallback
        case stateMismatch
        case timedOut
        /// The coordinator was torn down without ever producing a result. This
        /// should be unreachable — it exists so that a future ownership bug
        /// surfaces as a thrown error rather than as a leaked continuation and
        /// an infinite hang (which is exactly how the original bug presented).
        case abandoned
    }

    /// - Parameters:
    ///   - openBrowser: called once the listener is bound, with the actual
    ///     port; must return the `redirect_uri` used, so the caller can reuse
    ///     it for the token exchange.
    static func run(
        timeout: Duration,
        openBrowser: @escaping @Sendable (UInt16) -> String,
        expectedState: String
    ) async throws -> (code: String, redirectURI: String) {
        try await withCheckedThrowingContinuation { continuation in
            // `coordinator` is a local and would die the instant this closure
            // returns; every callback it installs captures `[weak self]`, so a
            // dead coordinator makes every resume path a silent no-op and the
            // continuation leaks (observed: "SWIFT TASK CONTINUATION MISUSE …
            // leaked its continuation", then an unbreakable hang, before the
            // listener even reached `.ready`). `start(timeout:)` therefore
            // installs a strong self-reference that keeps the coordinator
            // alive on its own; `finish(_:)` clears it. See `selfRetain`.
            let coordinator = Coordinator(expectedState: expectedState,
                                           openBrowser: openBrowser,
                                           continuation: continuation)
            coordinator.start(timeout: timeout)
        }
    }

    /// The last thing the user sees before returning to the app, so it is
    /// worth looking like it belongs to Raven rather than to 1996.
    ///
    /// Everything is inline and self-contained by necessity, not by
    /// preference: this is served from a one-shot loopback socket that
    /// answers exactly one request and closes, so a linked stylesheet,
    /// webfont or image would simply fail to load. No interpolation of
    /// request data either — every value here is a compile-time constant,
    /// which is what keeps a crafted callback out of the response body.
    static func callbackPage(success: Bool) -> String {
        let accent = success ? "#7c5cff" : "#ff5c7c"
        let title = success ? "Signed in" : "Sign-in failed"
        let body = success
            ? "Raven is connected to your Gmail account. You can close this tab — your inbox is already syncing."
            : "Raven could not complete the sign-in. You can close this tab and try connecting again from Raven's settings."
        let mark = success
            ? #"<path d="M20 32 L28 40 L44 24" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>"#
            : #"<path d="M24 24 L40 40 M40 24 L24 40" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round"/>"#

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title) — Raven</title>
        <style>
          :root {
            --accent: \(accent);
            --bg: #0b0b12;
            --panel: #14141f;
            --line: #262637;
            --text: #ececf5;
            --muted: #9a9ab0;
          }
          @media (prefers-color-scheme: light) {
            :root {
              --bg: #f4f4f8; --panel: #ffffff; --line: #e2e2ec;
              --text: #16161f; --muted: #5d5d70;
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh; display: grid; place-items: center;
            padding: 24px; background: var(--bg); color: var(--text);
            font: 15px/1.6 ui-sans-serif, -apple-system, "SF Pro Text", system-ui, sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          .card {
            width: min(440px, 100%); padding: 40px 36px; text-align: center;
            background: var(--panel); border: 1px solid var(--line);
            /* Chamfered corners echo the host's HUD panels. */
            clip-path: polygon(14px 0, 100% 0, 100% calc(100% - 14px), calc(100% - 14px) 100%, 0 100%, 0 14px);
            box-shadow: 0 24px 60px rgba(0,0,0,.35);
          }
          .mark {
            width: 64px; height: 64px; margin: 0 auto 22px; display: grid; place-items: center;
            color: var(--accent); border: 2px solid var(--accent); border-radius: 50%;
            box-shadow: 0 0 0 6px color-mix(in srgb, var(--accent) 12%, transparent);
          }
          h1 {
            margin: 0 0 10px; font-size: 21px; font-weight: 650; letter-spacing: .2px;
          }
          p { margin: 0; color: var(--muted); }
          .brand {
            margin-top: 28px; padding-top: 18px; border-top: 1px solid var(--line);
            font-size: 11px; letter-spacing: .18em; text-transform: uppercase; color: var(--muted);
          }
          .brand b { color: var(--accent); font-weight: 650; }
        </style>
        </head>
        <body>
          <main class="card">
            <div class="mark" aria-hidden="true">
              <svg width="40" height="40" viewBox="0 0 64 64">\(mark)</svg>
            </div>
            <h1>\(title)</h1>
            <p>\(body)</p>
            <div class="brand"><b>Raven</b> · Ainkrad</div>
          </main>
        </body>
        </html>
        """
    }

    /// All mutable state and callback wiring for one authorization attempt.
    /// Every `NWListener`/`NWConnection` callback used here runs on
    /// `queue: .main`, and the timeout is scheduled on that same queue via
    /// `DispatchQueue.main.asyncAfter` (not an unstructured `Task`, which
    /// would run on the concurrent executor and race the queue-confined
    /// callbacks) — so all mutable state on this type really is touched from
    /// one queue only, and `@unchecked Sendable` describes a mechanism that
    /// is actually true rather than an assumption. The exactly-once resume
    /// guarantee itself does not depend on that queue confinement, though:
    /// it is delegated to `OneShotResumeGuard`, which is independently lock-
    /// protected and safe even if called from genuinely concurrent contexts.
    private final class Coordinator: @unchecked Sendable {
        private let expectedState: String
        private let openBrowser: @Sendable (UInt16) -> String
        private let resumeGuard: OneShotResumeGuard<Result<(code: String, redirectURI: String), Error>>
        private var listener: NWListener?
        private var redirectURI = ""
        private var timeoutWorkItem: DispatchWorkItem?
        /// **This is what keeps the coordinator alive.** Nothing else holds a
        /// strong reference to it: `run(...)`'s local dies as the continuation
        /// closure returns, and every `NWListener`/`NWConnection` callback and
        /// the timeout work item deliberately capture `[weak self]` (so that a
        /// finished flow cannot be resurrected by a late callback). `start`
        /// sets this to `self`, which makes the coordinator own itself for the
        /// duration of the flow; **`finish(_:)` clears it**, which is the only
        /// release, and it happens after the continuation has been resumed.
        /// So the object's lifetime is exactly "listener started → continuation
        /// resumed", with no leak in either direction.
        ///
        /// Written and read only on `.main`, like all other state here.
        private var selfRetain: Coordinator?

        init(expectedState: String,
             openBrowser: @escaping @Sendable (UInt16) -> String,
             continuation: CheckedContinuation<(code: String, redirectURI: String), Error>) {
            self.expectedState = expectedState
            self.openBrowser = openBrowser
            self.resumeGuard = OneShotResumeGuard { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }

        deinit {
            // Unreachable while `selfRetain` is correct: the only release of
            // that reference happens inside `finish(_:)`, after the guard has
            // already fired. It is here as a hard backstop so that if the
            // ownership model is ever broken again, the caller gets a definite
            // `abandoned` error instead of a leaked continuation and a hang
            // that no timeout can break. `fire` is a no-op if already fired.
            resumeGuard.fire(.failure(ListenerError.abandoned))
        }

        func start(timeout: Duration) {
            // Take ownership of ourselves before anything can fail; every exit
            // path below runs through `finish(_:)`, which releases it again.
            selfRetain = self

            // The redirect is `http://localhost:PORT`, and "localhost" can
            // resolve to either the IPv4 loop (127.0.0.1) or the IPv6 loop
            // (::1) depending on the browser/OS resolver order — so the
            // listener must accept on both families, not just IPv4, or a
            // browser that resolves to ::1 will hit a closed port and the
            // flow will hang forever.
            //
            // This binds on `.any` — a genuine wildcard bind across every
            // interface and both address families, confirmed by `lsof`
            // showing `*:PORT`, not just "both loopback addresses." It is
            // NOT restricted to loopback by the bind itself. What restricts
            // it is `acceptLocalOnly = true`: Network.framework enforces,
            // per accepted connection, that the connection's peer resolves
            // to this same device before ever handing it to
            // `newConnectionHandler` — so a remote connection attempt is
            // rejected by the framework layer, not by the socket's bind
            // address. This is a real guarantee (it comes from the OS/
            // Network.framework, not from application-level filtering this
            // type does itself), but it is a single flag standing in for
            // what a loopback-only bind would otherwise guarantee
            // structurally — say so plainly rather than implying the two are
            // equivalent. An explicit loopback bind (`127.0.0.1` or `::1`
            // alone) was not used instead because `NWListener` binds one
            // local endpoint per instance, and binding to only one loopback
            // address would drop whichever family "localhost" didn't resolve
            // to — reintroducing the exact hang this fix exists to prevent.
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            guard let listener = try? NWListener(using: parameters, on: .any) else {
                finish(.failure(ListenerError.portUnavailable))
                return
            }
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.start(queue: .main)

            // Scheduled on the same queue as every Network callback above, so
            // the timeout can never race a connection callback that is
            // concurrently deciding whether to finish. `finish(_:)` cancels
            // this work item on every other exit path.
            let workItem = DispatchWorkItem { [weak self] in
                self?.finish(.failure(ListenerError.timedOut))
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout.timeInterval, execute: workItem)
        }

        private func handleListenerState(_ state: NWListener.State) {
            switch state {
            case .ready:
                guard let port = listener?.port else {
                    finish(.failure(ListenerError.portUnavailable))
                    return
                }
                redirectURI = openBrowser(port.rawValue)
            case .failed:
                finish(.failure(ListenerError.portUnavailable))
            case .waiting:
                // NWListener retries a `.waiting` state (e.g. transient bind
                // contention) on its own, but leaving it unhandled meant the
                // only way out of a genuinely stuck bind was the full
                // authorization timeout. Fail fast instead: a loopback bind
                // that cannot become ready promptly is not worth making the
                // user sit through several minutes of "please wait".
                finish(.failure(ListenerError.portUnavailable))
            default:
                break
            }
        }

        private func handle(_ connection: NWConnection) {
            connection.stateUpdateHandler = { state in
                if case .failed = state { connection.cancel() }
            }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
                defer { connection.cancel() }
                guard let self else { return }
                if error != nil {
                    self.finish(.failure(ListenerError.malformedCallback))
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8),
                      let line = CallbackRequestParser.firstLine(of: text) else {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.malformedCallback))
                    return
                }
                let callback = CallbackRequestParser.parse(requestLine: line)
                if let oauthError = callback.error {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.authorizationDenied(oauthError)))
                    return
                }
                guard let code = callback.code else {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.malformedCallback))
                    return
                }
                guard callback.state == self.expectedState else {
                    Self.respond(connection, success: false)
                    self.finish(.failure(ListenerError.stateMismatch))
                    return
                }
                Self.respond(connection, success: true)
                self.finish(.success(code))
            }
        }

        private func finish(_ result: Result<String, Error>) {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            listener?.cancel()
            switch result {
            case .success(let code): resumeGuard.fire(.success((code, redirectURI)))
            case .failure(let error): resumeGuard.fire(.failure(error))
            }
            // Release the self-reference taken in `start` — but only after the
            // continuation has been resumed, and via a local so that `self` is
            // not deallocated part-way through this method (which dropping the
            // last reference by a bare `selfRetain = nil` would risk).
            let lastReference = selfRetain
            selfRetain = nil
            withExtendedLifetime(lastReference) {}
        }

        private static func respond(_ connection: NWConnection, success: Bool) {
            let html = LoopbackCallbackListener.callbackPage(success: success)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
        }

    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// Guarantees a completion closure fires at most once, even under genuinely
/// concurrent invocation from multiple threads — independent of any queue or
/// actor confinement its caller may or may not have. Backed by a lock rather
/// than by "everything happens to run on the same queue," so the exactly-
/// once property holds regardless of how callers are scheduled. Stress-tested
/// in `GmailAuthTests.swift` by firing from many concurrent tasks and
/// asserting the completion runs exactly once.
final class OneShotResumeGuard<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private let onFirstFire: (T) -> Void

    init(onFirstFire: @escaping (T) -> Void) {
        self.onFirstFire = onFirstFire
    }

    /// Fires `onFirstFire` with `value` if (and only if) this is the first
    /// call. Returns whether this call was the one that fired.
    @discardableResult
    func fire(_ value: T) -> Bool {
        lock.lock()
        let shouldFire = !hasFired
        if shouldFire { hasFired = true }
        lock.unlock()
        if shouldFire { onFirstFire(value) }
        return shouldFire
    }
}
