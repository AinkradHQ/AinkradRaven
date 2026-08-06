import Foundation
import Network

/// The one mechanism by which an `NWConnection` can carry a STARTTLS mail port.
///
/// ## The problem
///
/// TLS is a protocol in `NWParameters`' stack. It is fixed when the connection is
/// created and it handshakes during `start()`, and there is no API to insert it
/// afterwards. Re-connecting is not an upgrade — the server is mid-session on the
/// *existing* socket, waiting for a ClientHello on it.
///
/// ## The mechanism
///
/// The stack is built as, top to bottom, `TLS → this framer → TCP`. A framer's
/// `start` may answer `.willMarkReady`, which suspends everything **above** it
/// until it calls `markReady()`. So:
///
/// 1. `start` returns `.willMarkReady`. TLS above is therefore inert: it has not
///    written a ClientHello and will not until told, and the connection as a whole
///    never reaches `.ready`.
/// 2. Meanwhile the plaintext prelude (`CAPABILITY`/`STARTTLS`, or
///    `EHLO`/`STARTTLS`) runs through this framer directly, via
///    `Control.write(_:)` and the input handler — *not* through
///    `NWConnection.send`/`receive`, which cannot be used before `.ready`.
/// 3. On `Control.upgrade()` the framer stops interposing (`passThroughInput` /
///    `passThroughOutput`) and calls `markReady()`. TLS above wakes up, performs
///    its handshake on the same socket, and the connection reaches `.ready` — or
///    `.failed`, if the handshake does not succeed.
///
/// After step 3 this framer is a pass-through with no state and no framing of its
/// own, which is exactly why `IMAPSession`/`SMTPSession` need no special case: a
/// post-upgrade `NWConnection.send` goes through TLS like any other connection's.
///
/// ## Why there is no plaintext fallback here
///
/// This type has no path back to step 2. `upgrade()` is one-way and idempotent,
/// there is no `downgrade`, and once `passThroughInput`/`passThroughOutput` are
/// set the framer cannot resume interposing. A failed handshake surfaces as the
/// connection failing, and `NetworkTransport.startTLS()` turns that into a thrown
/// error *and* cancels the connection. "Continue in the clear" is not a state this
/// design can express.
enum STARTTLSFramer {

    /// The key under which the per-connection `Control` travels in the framer's
    /// `NWProtocolFramer.Options`. Options are the supported handoff (a framer
    /// instance can read its own options), which is what lets this avoid a global
    /// registry keyed by connection identity — and the cross-claim race a registry
    /// would have when two accounts connect at once.
    static let controlKey = "com.ainkrad.raven.starttls.control"

    /// One shared definition. Per-connection state travels in the options, not in
    /// the definition, so there is no reason (and no supported way) to mint one
    /// definition per connection.
    static let definition = NWProtocolFramer.Definition(implementation: Implementation.self)

    /// Builds the parameters for an explicit-TLS endpoint: TLS on top, this framer
    /// under it, TCP at the bottom.
    ///
    /// `applicationProtocols` is ordered top-first, so appending puts the framer
    /// *below* TLS. That order is the whole design — a framer above TLS would see
    /// decrypted bytes and could not gate the handshake.
    static func parameters(control: Control) -> NWParameters {
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        let options = NWProtocolFramer.Options(definition: definition)
        options[controlKey] = control
        parameters.defaultProtocolStack.applicationProtocols.append(options)
        return parameters
    }

    /// The handle `NetworkTransport` holds on a live framer instance: plaintext
    /// I/O before the upgrade, and the one-way upgrade trigger.
    ///
    /// `@unchecked Sendable` describes a mechanism: every stored property is read
    /// and written under `lock`, and the two callbacks are invoked outside it so a
    /// handler that calls back in cannot deadlock.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var framer: NWProtocolFramer.Instance?
        private var didUpgrade = false
        private var onStart: (@Sendable () -> Void)?
        private var onInput: (@Sendable (Data) -> Void)?

        init() {}

        /// Installed by `NetworkTransport` before the connection is started, so
        /// neither callback can be missed.
        func setHandlers(onStart: @escaping @Sendable () -> Void,
                         onInput: @escaping @Sendable (Data) -> Void) {
            lock.lock()
            self.onStart = onStart
            self.onInput = onInput
            lock.unlock()
        }

        /// Called from the framer's `start`, and the moment plaintext I/O opens.
        func attach(_ instance: NWProtocolFramer.Instance) {
            lock.lock()
            framer = instance
            let notify = onStart
            lock.unlock()
            notify?()
        }

        /// Plaintext bytes read off the socket, from the framer's input handler.
        func deliverInput(_ data: Data) {
            lock.lock()
            let notify = onInput
            lock.unlock()
            notify?(data)
        }

        /// Writes plaintext bytes, returning whether they were handed to a live
        /// framer.
        ///
        /// Refused once the upgrade has been requested — after that point the only
        /// thing that may reach the socket is TLS's own output, and a stray
        /// plaintext write is exactly the credential leak this task exists to
        /// prevent. That refusal is falsifiable and is pinned by
        /// `STARTTLSFramerTests.aWriteRacingTheHandshakeNeverReachesTheServer`.
        ///
        /// There is deliberately no queue for writes issued before the framer
        /// attaches: `false` says "not written", which the caller turns into a
        /// thrown error. Buffering them would report success for bytes that may
        /// never leave, and "the write was accepted" must never be a guess.
        @discardableResult
        func write(_ data: Data) -> Bool {
            lock.lock()
            if didUpgrade { lock.unlock(); return false }
            guard let framer else { lock.unlock(); return false }
            lock.unlock()
            framer.async { framer.writeOutput(data: data) }
            return true
        }

        /// One-way and idempotent. Returns false if there is no framer to upgrade
        /// (the connection never started) — never "and so we carried on".
        @discardableResult
        func upgrade() -> Bool {
            lock.lock()
            guard let framer else { lock.unlock(); return false }
            if didUpgrade { lock.unlock(); return true }
            didUpgrade = true
            lock.unlock()
            framer.async {
                // Stop interposing FIRST, so that not one byte of TLS's ClientHello
                // can be routed into the plaintext input path.
                framer.passThroughInput()
                framer.passThroughOutput()
                framer.markReady()
            }
            return true
        }

    }

    /// The framer proper. It holds no protocol knowledge whatsoever — no lines, no
    /// CRLF, no `STARTTLS` verb. *When* to upgrade is the session's decision, sent
    /// down through `Control.upgrade()`; this only knows how.
    final class Implementation: NWProtocolFramerImplementation {
        static let label = "STARTTLS"

        private let control: Control?

        init(framer: NWProtocolFramer.Instance) {
            control = framer.options[STARTTLSFramer.controlKey] as? Control
        }

        /// `.willMarkReady` is the load-bearing return value: it is what keeps TLS
        /// above from handshaking. A `.ready` here would put the ClientHello on the
        /// wire before the server's `220`/`OK`, which is the failure mode this file
        /// exists to avoid.
        func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
            guard let control else {
                // No control means nothing can ever drive the upgrade, so readiness
                // would deadlock the connection. Fail it instead of hanging.
                framer.markFailed(error: NWError.posix(.EINVAL))
                return .willMarkReady
            }
            control.attach(framer)
            return .willMarkReady
        }

        /// Consumes everything available and hands it up as plaintext. After the
        /// upgrade `passThroughInput()` means this is never called again.
        func handleInput(framer: NWProtocolFramer.Instance) -> Int {
            while true {
                var chunk = Data()
                let parsed = framer.parseInput(minimumIncompleteLength: 1,
                                               maximumLength: 64 * 1024) { buffer, _ in
                    guard let buffer, !buffer.isEmpty else { return 0 }
                    chunk = Data(buffer)
                    return buffer.count
                }
                // `chunk.isEmpty` as well as `!parsed`: a parse that consumed
                // nothing must end the loop, or this spins forever on a socket
                // that has gone quiet.
                guard parsed, !chunk.isEmpty else { return 1 }
                control?.deliverInput(chunk)
            }
        }

        /// Unreachable in practice: before the upgrade nothing sits above this
        /// framer that can write (TLS is held inert and the connection is not
        /// `.ready`), and after it `passThroughOutput()` bypasses this handler. It
        /// is a faithful no-framing pass-through so that, if it ever is reached,
        /// bytes go out unaltered rather than being dropped.
        func handleOutput(framer: NWProtocolFramer.Instance,
                          message: NWProtocolFramer.Message,
                          messageLength: Int,
                          isComplete: Bool) {
            try? framer.writeOutputNoCopy(length: messageLength)
        }

        func wakeup(framer: NWProtocolFramer.Instance) {}

        /// `true` means "this framer is done and the stack may finish stopping".
        /// There is nothing to flush: plaintext writes are handed to
        /// `writeOutput` as they are made, never buffered here.
        func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

        func cleanup(framer: NWProtocolFramer.Instance) {}
    }
}
