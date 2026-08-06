import Foundation

/// The seam between "bytes on a socket" and every line of protocol logic above
/// it. `IMAPSession`/`SMTPSession` and everything they feed are written against
/// this protocol only, so they are exercised in tests by a scripted double
/// (`ScriptedTransport`) rather than by a real server — which is what makes the
/// lexer, the command channel and the delta strategy pure unit tests. The one
/// conformer that touches a socket (`NetworkTransport`) is therefore the only
/// untested file in the stack, and it deliberately holds no logic: it knows
/// nothing about IMAP, SMTP, commands, tags, lines or CRLF.
///
/// `read()` returns whatever arrived, in whatever chunking the network chose —
/// it is NOT line- or response-oriented, and callers must never assume a read
/// contains a whole line, a whole response, or a whole literal. Splitting bytes
/// into protocol units is the caller's job (Task 7's lexer).
protocol MailTransport: AnyObject, Sendable {
    /// Establishes the connection (including the TLS handshake when the
    /// endpoint uses implicit TLS). Must be called before `send`/`read`.
    func connect() async throws
    func send(_ bytes: Data) async throws
    /// Suspends until at least one byte is available. Never returns empty data:
    /// a clean peer close is reported as `MailTransportError.closed`, so a
    /// caller cannot mistake end-of-stream for "nothing yet" and spin.
    func read() async throws -> Data
    /// Upgrades an already-established plaintext connection to TLS. The
    /// protocol-level negotiation that precedes it (IMAP's `STARTTLS`, SMTP's
    /// `STARTTLS`) is the caller's business; this call is only the handshake.
    func startTLS() async throws
    /// Idempotent. Fails every pending `read()`/`send()` with
    /// `MailTransportError.closed` rather than leaving them suspended.
    func close() async
}

/// How TLS is applied to a connection. Named for the two shapes mail servers
/// actually offer (993/465 vs 143/587) rather than for the transport's mechanics.
enum MailTransportTLS: Sendable, Equatable {
    /// TLS from the first byte — the handshake is part of `connect()`.
    case implicit
    /// Connect in plaintext; the caller negotiates an upgrade and then calls
    /// `startTLS()`.
    case explicit
}

struct MailTransportEndpoint: Sendable, Equatable {
    let host: String
    let port: UInt16
    let tls: MailTransportTLS

    init(host: String, port: UInt16, tls: MailTransportTLS) {
        self.host = host
        self.port = port
        self.tls = tls
    }
}

enum MailTransportError: Error, Equatable {
    /// `send`/`read`/`startTLS` before a successful `connect()`.
    case notConnected
    /// The connection is gone — cancelled, closed by us, or closed by the peer.
    /// Also what every pending call fails with on `close()`, so no continuation
    /// is ever left suspended.
    case closed
    case connectionFailed(String)
    case tlsFailed(String)
    /// `connect()` or `read()` exceeded its deadline. A hung read must surface
    /// as an error: the sync engine has no other way out of it.
    case timedOut
    /// The transport cannot perform an in-place TLS upgrade. Since Task 15b
    /// `NetworkTransport` can, via `STARTTLSFramer`; this remains for an endpoint
    /// that was not built for one (an implicit-TLS endpoint has no framer to
    /// release) and for any other conformer that genuinely cannot. It is never a
    /// policy refusal, and it is never followed by a plaintext continuation.
    case tlsUpgradeUnsupported
    /// Scripted-double only: the test script had no more bytes to hand back.
    /// A deterministic error rather than a suspended read, so a wrong
    /// expectation in a test fails the test instead of hanging the suite.
    case scriptExhausted(String)
}
