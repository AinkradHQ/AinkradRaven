import Foundation
import Network
@testable import RavenFeature

/// A one-connection plaintext TCP server on 127.0.0.1, for the only tests in this
/// repo that must touch a real socket: `STARTTLSFramerTests`.
///
/// Everything else in the IMAP/SMTP stack is tested against `ScriptedTransport`,
/// because everything else is logic. `STARTTLSFramer` is not logic — it is a
/// negotiation with `Network.framework` about when TLS is allowed to start, and a
/// double cannot disagree with the framework. So this exists, and it is
/// deliberately the dumbest server possible: it speaks a greeting, answers
/// needles with fixed bytes, and records what it was sent. It has no TLS identity
/// and therefore cannot complete a handshake — it stalls instead, which is
/// exactly what the no-fallback tests need: a handshake that is genuinely
/// in flight, for as long as they want to write into it.
///
/// `@unchecked Sendable` describes a mechanism: every stored property is touched
/// under `lock` or on `queue` only.
final class LoopbackTCPServer: @unchecked Sendable {
    struct Rule: Sendable {
        let needle: String
        let reply: Data

        init(needle: String, reply: String) {
            self.needle = needle
            self.reply = Data(reply.utf8)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.ainkrad.raven.tests.loopback-server")
    private let lock = NSLock()
    private let greeting: Data
    private var rules: [Rule]
    private var connection: NWConnection?
    private var receivedBytes = Data()
    private var matched: Set<String> = []

    private(set) var port: UInt16 = 0

    init(greeting: String, rules: [Rule]) throws {
        self.greeting = Data(greeting.utf8)
        self.rules = rules
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Everything the client sent, in order.
    var received: Data {
        lock.lock(); defer { lock.unlock() }
        return receivedBytes
    }

    var receivedText: String { String(decoding: received, as: UTF8.self) }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let guard_ = OneShotResumeGuard<Result<Void, any Error>> { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port?.rawValue ?? 0
                    guard_.fire(self.port == 0
                                ? .failure(NWError.posix(.EADDRNOTAVAIL))
                                : .success(()))
                case .failed(let error):
                    guard_.fire(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        lock.lock()
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            connection.send(content: self.greeting, completion: .contentProcessed { _ in })
            self.receiveLoop(connection)
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else { return }
            guard let data, !data.isEmpty else { self.receiveLoop(connection); return }
            self.lock.lock()
            self.receivedBytes.append(data)
            let text = String(decoding: self.receivedBytes, as: UTF8.self)
            let due = self.rules.first { !self.matched.contains($0.needle) && text.contains($0.needle) }
            if let due { self.matched.insert(due.needle) }
            self.lock.unlock()
            guard let due else { self.receiveLoop(connection); return }
            connection.send(content: due.reply,
                            completion: .contentProcessed { _ in self.receiveLoop(connection) })
        }
    }
}
