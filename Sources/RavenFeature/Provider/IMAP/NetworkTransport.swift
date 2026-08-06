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
    /// Whoever is waiting for the transport to become usable *next*. Exactly one
    /// call is ever registered here at a time, and which event fires it depends on
    /// where in the endpoint's lifecycle we are:
    ///   * implicit — `connect()`, fired by the connection reaching `.ready`
    ///     (which for an implicit endpoint means TLS is up).
    ///   * explicit — `connect()`, fired by the framer starting, i.e. TCP is up
    ///     and the plaintext prelude may begin; then `startTLS()`, fired by the
    ///     connection reaching `.ready`, which for an explicit endpoint happens
    ///     only once the framer has released TLS and TLS has handshaken.
    /// Failures do not come through here — they come through `failAll`, so a
    /// single teardown path covers every suspended call.
    private var gateWaiters: [@Sendable () -> Void] = []

    // MARK: Explicit-TLS (STARTTLS) state — all queue-confined

    /// Non-nil only for an explicit endpoint. The live framer's handle.
    private var framerControl: STARTTLSFramer.Control?
    /// Plaintext bytes read off the framer and not yet handed to a `read()`.
    private var plaintextChunks: [Data] = []
    /// `read()`s parked on an empty plaintext buffer, each paired with the waiter
    /// that lets `close()`/a failure/a timeout kill it.
    private var plaintextReaders: [(waiter: Waiter, deliver: @Sendable (Data) -> Void)] = []
    /// Set the instant `startTLS()` is entered, and never cleared. Everything that
    /// could put a plaintext byte on the wire is gated on this being false, so the
    /// window between "upgrade requested" and "handshake finished" is not a window
    /// in which a credential can be written.
    private var didRequestUpgrade = false

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
                // TLS IS in the stack from the start — it is simply held inert by
                // the framer below it until `startTLS()`. Building the stack
                // without TLS would leave nothing to upgrade *into*, which is the
                // whole reason the old implementation could only refuse.
                let control = STARTTLSFramer.Control()
                self.framerControl = control
                control.setHandlers(
                    onStart: { [weak self] in
                        guard let self else { return }
                        self.queue.async { self.fireGate() }
                    },
                    onInput: { [weak self] data in
                        guard let self else { return }
                        self.queue.async { self.acceptPlaintext(data) }
                    })
                parameters = STARTTLSFramer.parameters(control: control)
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
            self.gateWaiters.append { [weak self] in
                waiter.timeout?.cancel()
                self?.discard(waiter)
                guard_.fire(.success(()))
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.fireGate()
                case .failed(let error):
                    // Every OTHER suspended call dies with the connection too;
                    // this is the path that would otherwise strand a `read()`.
                    // Once the upgrade has been asked for, a connection failure
                    // IS the TLS handshake failing — reported as `.tlsFailed` so
                    // no caller can mistake it for an ordinary drop and retry in
                    // the clear.
                    self.failAll(self.didRequestUpgrade
                                 ? .tlsFailed("\(error)")
                                 : .connectionFailed("\(error)"))
                case .cancelled:
                    self.failAll(.closed)
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
            // The two branches do NOT promise the same thing, and cannot:
            //   * the TLS branch resolves on `contentProcessed` — the bytes have
            //     been handed to the protocol stack;
            //   * this branch resolves once the framer has accepted them.
            // `NWProtocolFramer` offers no completion for `writeOutput`, so there
            // is nothing to await. What was closed instead is the gap that made
            // the difference *observable*: `Control.write` no longer queues bytes
            // for a framer that has not attached — it returns false, and that
            // becomes a thrown `.notConnected` here rather than a reported success
            // for a byte that might never leave. What remains is ordering-safe:
            // the framer processes `writeOutput` calls in order on its own queue,
            // and a failure after acceptance surfaces on the connection like any
            // other, failing every suspended call.
            if self.usesPlaintextPath {
                guard let control = self.framerControl, control.write(bytes) else {
                    guard_.fire(.failure(.notConnected))
                    return
                }
                guard_.fire(.success(()))
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
                    self?.discardPlaintextReader(waiter)
                    self?.discard(waiter)
                    guard_.fire(.failure(.timedOut))
                }
                if self.usesPlaintextPath {
                    if !self.plaintextChunks.isEmpty {
                        waiter.timeout?.cancel()
                        self.discard(waiter)
                        guard_.fire(.success(self.plaintextChunks.removeFirst()))
                        return
                    }
                    self.plaintextReaders.append((waiter, { [weak self] data in
                        waiter.timeout?.cancel()
                        self?.discard(waiter)
                        guard_.fire(.success(data))
                    }))
                    return
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

    /// Releases the `STARTTLSFramer` sitting under TLS and suspends until the
    /// handshake either completes or fails.
    ///
    /// `NWConnection` still cannot insert TLS into a running stack — that has not
    /// changed. What changed is that for an explicit endpoint TLS was in the stack
    /// all along, held inert by the framer below it, so this is a *release* rather
    /// than an insertion. See `STARTTLSFramer` for the mechanism.
    ///
    /// **There is no plaintext fallback and no way to add one.** Three independent
    /// reasons, so that losing any single one is still safe:
    ///   1. `didRequestUpgrade` is set before anything else happens and is never
    ///      cleared. `usesPlaintextPath` is false from that instant, so `send()`
    ///      cannot reach the framer's plaintext write path again — not even while
    ///      the handshake is in flight.
    ///   2. `STARTTLSFramer.Control.write` independently refuses once upgraded.
    ///   3. Every failure path below cancels the connection outright before
    ///      throwing, so a caller that ignores the error finds a dead transport
    ///      rather than a plaintext one.
    ///
    /// `tlsUpgradeUnsupported` survives for the one case that is genuinely
    /// unsupported: an endpoint that was not built for an upgrade. An implicit
    /// endpoint has no framer to release and is already encrypted; asking it to
    /// "upgrade" is a caller bug, and answering "fine" would be a lie.
    func startTLS() async throws {
        guard endpoint.tls == .explicit else { throw MailTransportError.tlsUpgradeUnsupported }
        try await suspendVoid { guard_ in
            guard !self.isClosed, let connection = self.connection,
                  let control = self.framerControl else {
                guard_.fire(.failure(self.isClosed ? .closed : .notConnected))
                return
            }
            if self.didRequestUpgrade {
                // Idempotent, and only because the connection is already `.ready`
                // — i.e. the handshake already succeeded. A second call during a
                // handshake in flight cannot happen: the sessions above are
                // strictly lock-step.
                guard_.fire(connection.state == .ready ? .success(()) : .failure(.closed))
                return
            }
            self.didRequestUpgrade = true
            // Belt and braces behind guard 1, and **unobservable today**: once
            // `didRequestUpgrade` is set, `read()` takes the `connection.receive`
            // path and never consults `plaintextChunks` again, so deleting this
            // line changes no behaviour any test can see (verified by mutation).
            // It is kept because it makes the discard RFC 3207 §4.2 / RFC 3501
            // require true of the *state* as well as of the read path, so a future
            // edit to `usesPlaintextPath` cannot resurrect a pre-TLS byte.
            self.plaintextChunks.removeAll()

            let waiter = self.register { guard_.fire(.failure($0)) }
            self.scheduleTimeout(self.connectTimeout, on: waiter) { [weak self] in
                self?.discard(waiter)
                // A handshake that never answers must not leave a usable socket
                // behind, so this tears the connection down rather than just
                // failing the call.
                self?.hardFail(.tlsFailed("the TLS handshake did not complete in time"))
                guard_.fire(.failure(.tlsFailed("the TLS handshake did not complete in time")))
            }
            self.gateWaiters.append { [weak self] in
                waiter.timeout?.cancel()
                self?.discard(waiter)
                guard_.fire(.success(()))
            }
            guard control.upgrade() else {
                waiter.timeout?.cancel()
                self.discard(waiter)
                self.hardFail(.notConnected)
                guard_.fire(.failure(.notConnected))
                return
            }
        }
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

    private func discardPlaintextReader(_ waiter: Waiter) {
        plaintextReaders.removeAll { $0.waiter === waiter }
    }

    /// True exactly while bytes must go through the framer in the clear: an
    /// explicit endpoint whose upgrade has not been asked for yet.
    private var usesPlaintextPath: Bool {
        endpoint.tls == .explicit && !didRequestUpgrade
    }

    /// Releases whoever is waiting on the transport becoming usable. Draining
    /// before calling matters: a handler that registers a new gate waiter (the
    /// `connect()` → `startTLS()` handover) must not be fired by the event that
    /// released the previous one.
    private func fireGate() {
        let pending = gateWaiters
        gateWaiters = []
        for fire in pending { fire() }
    }

    /// Plaintext bytes off the framer: hand to the oldest parked `read()`, else
    /// buffer. Ignored once the upgrade has been requested — see `startTLS`.
    private func acceptPlaintext(_ data: Data) {
        guard usesPlaintextPath, !data.isEmpty else { return }
        if !plaintextReaders.isEmpty {
            let reader = plaintextReaders.removeFirst()
            discard(reader.waiter)
            reader.deliver(data)
            return
        }
        plaintextChunks.append(data)
    }

    /// Fails every suspended call AND kills the socket. Used where continuing
    /// would be worse than failing — a TLS handshake that never completed.
    private func hardFail(_ error: MailTransportError) {
        isClosed = true
        failAll(error)
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    /// Fails every suspended call. Each `fire` is a no-op if that call already
    /// resumed, so this is safe to call from several teardown paths.
    private func failAll(_ error: MailTransportError) {
        // Parked plaintext reads are registered in `waiters` too, so failing the
        // waiters resumes them; this only drops the now-dead delivery closures.
        plaintextReaders = []
        plaintextChunks = []
        gateWaiters = []
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
