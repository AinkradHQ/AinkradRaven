import Foundation
import Network

/// The one `MailTransport` conformer that touches a socket. It is deliberately
/// the dumbest file in the stack: it opens a TCP (optionally TLS) connection,
/// pushes `Data` in, hands `Data` out, and closes. It knows nothing about the
/// protocol running over it — no commands, no tags, no lines, no CRLF, no
/// literals, no greeting. Everything with logic in it lives above this seam and
/// is tested against `ScriptedTransport`.
///
/// The continuation discipline here is copied from `LoopbackCallbackListener`,
/// which shipped a leaked continuation once and now documents why:
///   1. Every `NWConnection` callback and every timeout runs on ONE private
///      serial queue, so all mutable state below really is single-queue
///      confined and `@unchecked Sendable` describes a mechanism rather than a
///      hope. Timeouts use `DispatchWorkItem` on that same queue, never an
///      unstructured `Task` (which would run on the concurrent executor and
///      race the callbacks).
///   2. Every suspended call resumes through a `OneShotResumeGuard`, which is
///      lock-protected and fires at most once — so a callback that arrives
///      after a timeout (or after `close()`) is a no-op, not a double resume.
///   3. Every pending call is registered in `waiters` before it can suspend, so
///      `close()`, a connection failure and `deinit` can all fail it. A `read()`
///      that never resumes would hang the sync engine forever with no timeout
///      able to break it; there is no path here that leaves one suspended.
final class NetworkTransport: MailTransport, @unchecked Sendable {
    /// One suspended call. Identity is the object, so a completed call can
    /// remove exactly its own entry.
    /// `@unchecked Sendable` because every field is written and read on `queue`
    /// only (the `DispatchWorkItem` it carries is scheduled on that same queue),
    /// and `fail` resumes through a lock-protected `OneShotResumeGuard`.
    private final class Waiter: @unchecked Sendable {
        let fail: @Sendable (MailTransportError) -> Void
        /// The timeout for this call, cancelled by whichever completion wins.
        var timeout: DispatchWorkItem?
        init(fail: @escaping @Sendable (MailTransportError) -> Void) { self.fail = fail }
    }

    private let endpoint: MailTransportEndpoint
    private let connectTimeout: Duration
    private let readTimeout: Duration
    /// Every callback, every timeout and every state mutation runs here.
    private let queue = DispatchQueue(label: "com.ainkrad.raven.mail-transport")
    private var connection: NWConnection?
    private var isClosed = false
    private var waiters: [Waiter] = []

    init(endpoint: MailTransportEndpoint,
         connectTimeout: Duration = .seconds(30),
         readTimeout: Duration = .seconds(60)) {
        self.endpoint = endpoint
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    deinit {
        // Hard backstop, unreachable while the ownership above is correct: a
        // future bug surfaces as a definite error rather than a hang.
        let stranded = waiters
        waiters = []
        for waiter in stranded { waiter.fail(.closed) }
        connection?.cancel()
    }

    // MARK: - MailTransport

    func connect() async throws {
        try await suspendVoid { guard_ in
            guard !self.isClosed else { guard_.fire(.failure(.closed)); return }
            guard self.connection == nil else { guard_.fire(.success(())); return }

            let parameters: NWParameters
            switch self.endpoint.tls {
            case .implicit:
                parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
            case .explicit:
                parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            }
            guard let port = NWEndpoint.Port(rawValue: self.endpoint.port) else {
                guard_.fire(.failure(.connectionFailed("invalid port \(self.endpoint.port)")))
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(self.endpoint.host),
                                          port: port,
                                          using: parameters)
            self.connection = connection

            let waiter = self.register { guard_.fire(.failure($0)) }
            self.scheduleTimeout(self.connectTimeout, on: waiter) { [weak self] in
                self?.discard(waiter)
                self?.failAll(.timedOut)
                guard_.fire(.failure(.timedOut))
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    waiter.timeout?.cancel()
                    self.discard(waiter)
                    guard_.fire(.success(()))
                case .failed(let error):
                    waiter.timeout?.cancel()
                    self.discard(waiter)
                    // Every OTHER suspended call dies with the connection too;
                    // this is the path that would otherwise strand a `read()`.
                    self.failAll(.connectionFailed("\(error)"))
                    guard_.fire(.failure(.connectionFailed("\(error)")))
                case .cancelled:
                    waiter.timeout?.cancel()
                    self.discard(waiter)
                    self.failAll(.closed)
                    guard_.fire(.failure(.closed))
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func send(_ bytes: Data) async throws {
        try await suspendVoid { guard_ in
            guard !self.isClosed, let connection = self.connection else {
                guard_.fire(.failure(self.isClosed ? .closed : .notConnected))
                return
            }
            let waiter = self.register { guard_.fire(.failure($0)) }
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                self?.discard(waiter)
                if let error {
                    guard_.fire(.failure(.connectionFailed("\(error)")))
                } else {
                    guard_.fire(.success(()))
                }
            })
        }
    }

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let guard_ = OneShotResumeGuard<Result<Data, MailTransportError>> { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            queue.async {
                guard !self.isClosed, let connection = self.connection else {
                    guard_.fire(.failure(self.isClosed ? .closed : .notConnected))
                    return
                }
                let waiter = self.register { guard_.fire(.failure($0)) }
                self.scheduleTimeout(self.readTimeout, on: waiter) { [weak self] in
                    self?.discard(waiter)
                    guard_.fire(.failure(.timedOut))
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    [weak self] data, _, isComplete, error in
                    waiter.timeout?.cancel()
                    self?.discard(waiter)
                    if let error {
                        guard_.fire(.failure(.connectionFailed("\(error)")))
                        return
                    }
                    if let data, !data.isEmpty {
                        guard_.fire(.success(data))
                        return
                    }
                    // Empty data with `isComplete` is a clean peer close, and
                    // empty data without it cannot be distinguished usefully:
                    // either way, reporting `.closed` keeps a caller from
                    // spinning on zero-byte reads.
                    _ = isComplete
                    guard_.fire(.failure(.closed))
                }
            }
        }
    }

    /// **`NWConnection` cannot upgrade an established plaintext connection to
    /// TLS.** TLS is a protocol in the parameters' stack, fixed when the
    /// connection is created and handshaken during `start`; there is no public
    /// API to insert it afterwards, and re-connecting is not an upgrade — the
    /// server is mid-session on the existing socket waiting for a ClientHello.
    ///
    /// So this refuses, loudly and typed, instead of pretending. Consequences,
    /// recorded here because later tasks depend on them:
    ///   * Implicit TLS (IMAPS 993, SMTPS 465) is fully supported by
    ///     `connect()` and is the supported production path.
    ///   * Explicit STARTTLS (143/587) needs a real implementation. The only
    ///     Network.framework-shaped option is an `NWProtocolFramer` placed
    ///     below TLS that performs the caller-supplied plaintext prelude and
    ///     defers readiness until the upgrade point — which puts negotiation
    ///     logic into this otherwise logic-free, untestable file, so it is
    ///     deliberately NOT done here.
    ///   * `ScriptedTransport.startTLS()` works and records the upgrade point,
    ///     so Task 9's and Task 15's "no credential byte before TLS" assertions
    ///     are unaffected.
    func startTLS() async throws {
        throw MailTransportError.tlsUpgradeUnsupported
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isClosed = true
                self.failAll(.closed)
                self.connection?.stateUpdateHandler = nil
                self.connection?.cancel()
                self.connection = nil
                continuation.resume()
            }
        }
    }

    // MARK: - Queue-confined helpers (all of these run on `queue` only)

    private func suspendVoid(
        _ body: @escaping @Sendable (OneShotResumeGuard<Result<Void, MailTransportError>>) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let guard_ = OneShotResumeGuard<Result<Void, MailTransportError>> { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            queue.async { body(guard_) }
        }
    }

    private func register(fail: @escaping @Sendable (MailTransportError) -> Void) -> Waiter {
        let waiter = Waiter(fail: fail)
        waiters.append(waiter)
        return waiter
    }

    private func discard(_ waiter: Waiter) {
        waiters.removeAll { $0 === waiter }
    }

    /// Fails every suspended call. Each `fire` is a no-op if that call already
    /// resumed, so this is safe to call from several teardown paths.
    private func failAll(_ error: MailTransportError) {
        let stranded = waiters
        waiters = []
        for waiter in stranded { waiter.fail(error) }
    }

    private func scheduleTimeout(_ duration: Duration,
                                 on waiter: Waiter,
                                 _ body: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem(block: body)
        waiter.timeout = item
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
