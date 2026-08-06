import Foundation

/// Why an IMAP login was refused, or refused to be attempted.
///
/// **Every case carries only server-authored text or a mechanism name.** No case
/// can hold a password, an access token, or a base64 SASL response — that is the
/// point of the type being this narrow, and `IMAPAuthTests` asserts it by
/// running the real credentials through every failure path and scanning the
/// resulting strings.
enum IMAPAuthError: Error, Equatable {
    /// The connection was made in plaintext expecting an in-place `STARTTLS`
    /// upgrade, which this transport stack cannot perform (see
    /// `NetworkTransport.startTLS()` and `MailTransportError.tlsUpgradeUnsupported`).
    ///
    /// Refused *before the first byte of the command*, not after a failed
    /// upgrade: the alternative — attempt, fail, and let a caller retry — has a
    /// version where the retry lands on the plaintext socket, and no error
    /// message prevents that as reliably as never having sent anything. Raven's
    /// IMAP support is implicit-TLS-only (993/465) and this is where that
    /// decision is enforced.
    case explicitTLSUnsupported
    /// `LOGINDISABLED` was advertised and no SASL mechanism we can use was. The
    /// server has told us a plaintext `LOGIN` will be rejected; sending it anyway
    /// would put the password on the wire for nothing.
    case plaintextLoginDisabled
    /// The credential's SASL mechanism is not in the server's capability list.
    /// Carries the mechanism name (`XOAUTH2`, `PLAIN`), never the credential.
    case mechanismUnavailable(String)
    /// The server answered `NO`/`BAD`. The text is the server's own.
    case rejected(String)
}

/// Logs in over an existing `IMAPSession`, both ways the mail providers Raven
/// targets offer: an app-specific password, and OAuth 2.0 via the `XOAUTH2` SASL
/// mechanism.
///
/// ## It goes through the session, and only the session
///
/// This type holds an `IMAPSession` and never a transport. Authentication is
/// ordinary tagged-command traffic — the credential rides on the same tag
/// counter, the same pipelining rules and the same continuation discipline as
/// every other command — so there is no second write path to the socket that
/// could sidestep the session's teardown guarantees. In particular the SASL
/// challenge/response exchange uses `IMAPCommand.reactiveContinuationLines`, which
/// session's read loop drives, rather than a bespoke read/write loop of its own.
///
/// ## It holds no store
///
/// No `PluginSecretStore`, no `PluginDocumentStore`, no key names. Credentials
/// arrive as an `IMAPCredential` value built by `IMAPAppPasswordStore` /
/// `IMAPOAuthCredentialSource` on the main actor. That is what makes "no
/// credential byte reaches a document" a structural property of this file rather
/// than an observed one.
struct IMAPAuthenticator: Sendable {
    private let session: IMAPSession
    /// How the connection was established. `.explicit` is refused outright.
    private let security: MailTransportTLS

    init(session: IMAPSession, security: MailTransportTLS) {
        self.session = session
        self.security = security
    }

    /// Authenticates and returns the post-authentication capability list.
    ///
    /// The order of the steps is load-bearing and is asserted by tests:
    ///
    /// 1. **TLS posture first.** Nothing — not `CAPABILITY`, certainly not the
    ///    credential — is written on a connection that is not already encrypted.
    /// 2. **`PREAUTH` short-circuits.** A pre-authenticated greeting means the
    ///    server has already decided who we are; sending a credential would leak
    ///    it for no benefit and some servers answer `BAD`.
    /// 3. **Capabilities before the mechanism choice**, from the cache the
    ///    greeting's `[CAPABILITY …]` code usually fills, so the common case
    ///    costs no round trip.
    /// 4. **Re-read capabilities after success**, because servers change the list
    ///    at that point (`AUTH=` mechanisms vanish, `IDLE`/`QUOTA` appear).
    @discardableResult
    func authenticate(_ credential: IMAPCredential,
                      greeting: IMAPGreeting) async throws -> Set<String> {
        guard security == .implicit else { throw IMAPAuthError.explicitTLSUnsupported }
        if greeting.kind == .preauth { return try await session.capabilities() }
        let capabilities = try await session.capabilities()
        let command = try Self.command(for: credential, capabilities: capabilities)
        do {
            try await session.execute(command)
        } catch let error as IMAPSessionError {
            if case .commandFailed(_, _, let text) = error { throw IMAPAuthError.rejected(text) }
            throw error
        }
        return try await session.capabilitiesAfterAuthentication()
    }

    // MARK: - Mechanism selection

    /// Picks the command for a credential against an advertised capability list.
    ///
    /// `static` and pure so the choice can be asserted directly, byte for byte,
    /// without a transport.
    static func command(for credential: IMAPCredential,
                        capabilities: Set<String>) throws -> IMAPCommand {
        let saslIR = capabilities.contains("SASL-IR")
        switch credential {
        case .xoauth2(let username, let accessToken):
            guard capabilities.contains("AUTH=XOAUTH2") else {
                throw IMAPAuthError.mechanismUnavailable("XOAUTH2")
            }
            return xoauth2Command(username: username, accessToken: accessToken, saslIR: saslIR)
        case .appPassword(let username, let password):
            // `AUTHENTICATE PLAIN` is preferred over `LOGIN` wherever it exists:
            // it is what `LOGINDISABLED` servers leave open, and it is one
            // round trip either way. `LOGINDISABLED` disables the LOGIN
            // *command* (RFC 3501 §7.2.1) — it does not disable SASL PLAIN — so
            // the refusal below is reached only when no usable mechanism remains.
            if capabilities.contains("AUTH=PLAIN") {
                return plainCommand(username: username, password: password, saslIR: saslIR)
            }
            guard capabilities.contains("LOGINDISABLED") == false else {
                throw IMAPAuthError.plaintextLoginDisabled
            }
            return loginCommand(username: username, password: password)
        }
    }

    // MARK: - Commands

    /// `LOGIN "user" "password"`. The password is `.redacted`, so the command's
    /// `description` renders `<redacted>` while the wire bytes are unchanged.
    static func loginCommand(username: String, password: String) -> IMAPCommand {
        IMAPCommand("LOGIN", [.text(username), .redacted(.text(password))])
    }

    /// SASL `PLAIN` (RFC 4616): `authzid \0 authcid \0 passwd`, base64'd, with an
    /// empty authorization identity.
    static func plainCommand(username: String, password: String, saslIR: Bool) -> IMAPCommand {
        let response = base64(plainInitialResponse(username: username, password: password))
        return saslCommand(mechanism: "PLAIN", initialResponse: response,
                           saslIR: saslIR, answersFailureChallenge: false)
    }

    /// SASL `XOAUTH2`: `user=<addr>^Aauth=Bearer <token>^A^A`, base64'd, where
    /// `^A` is `\u{01}`.
    static func xoauth2Command(username: String, accessToken: String, saslIR: Bool) -> IMAPCommand {
        let response = base64(xoauth2InitialResponse(username: username, accessToken: accessToken))
        // `answersFailureChallenge: true` — see `saslCommand`. XOAUTH2 is the
        // mechanism that needs it: a failure arrives as `+ <base64 JSON>`, not as
        // a tagged `NO`, and the server will not send the `NO` until the client
        // has acknowledged the challenge with an empty line.
        return saslCommand(mechanism: "XOAUTH2", initialResponse: response,
                           saslIR: saslIR, answersFailureChallenge: true)
    }

    // The three payload helpers below are thin forwarders to `SASLMechanism`,
    // which is where the bytes actually live now: SMTP's `AUTH` (Task 15) needs
    // the identical payloads under different command framing, and a second copy
    // of a byte layout nothing but a live server can validate is the wrong kind
    // of duplication. They stay here, with these names and signatures, because
    // `IMAPAuthTests` pins them directly — the extraction moved the bytes, not
    // the contract.

    /// The raw (pre-base64) SASL PLAIN response. Separate so a test can assert
    /// the exact byte layout, NUL separators included.
    static func plainInitialResponse(username: String, password: String) -> Data {
        SASLMechanism.plainInitialResponse(username: username, password: password)
    }

    /// The raw (pre-base64) XOAUTH2 response, exactly
    /// `user=<addr>\u{01}auth=Bearer <token>\u{01}\u{01}`.
    static func xoauth2InitialResponse(username: String, accessToken: String) -> Data {
        SASLMechanism.xoauth2InitialResponse(username: username, accessToken: accessToken)
    }

    static func base64(_ data: Data) -> String { SASLMechanism.base64(data) }

    /// Builds `AUTHENTICATE <mech>` with the initial response placed where the
    /// server's capabilities allow it.
    ///
    /// - With `SASL-IR` (RFC 4959) the base64 response is an atom on the command
    ///   line, saving a round trip. It is `.redacted` so it cannot be logged.
    /// - Without it, the response must wait for the server's `+ ` and is sent as
    ///   a bare continuation line. Sending it inline anyway is a protocol
    ///   violation, so this is never inferred.
    ///
    /// - Parameter answersFailureChallenge: appends a final empty continuation
    ///   line. A mechanism that reports failure as a *challenge* rather than as a
    ///   tagged completion leaves the exchange half-open; the client must send an
    ///   empty line for the server to then send its `NO`.
    ///
    /// Every line here is a `reactiveContinuationLines` entry, never a wire chunk,
    /// and the command is `isExclusive`. Both matter: a SASL ack the server does
    /// not ask for must not be registered as an expected continuation, or it
    /// consumes a *pipelined* command's `+ ready for literal` and desynchronises
    /// the connection. See `IMAPCommand.reactiveContinuationLines`.
    private static func saslCommand(mechanism: String, initialResponse: String,
                                    saslIR: Bool, answersFailureChallenge: Bool) -> IMAPCommand {
        let crlf = Data([0x0D, 0x0A])
        var lines: [Data] = []
        var arguments: [IMAPCommand.Argument] = [.atom(mechanism)]
        if saslIR {
            arguments.append(.redacted(.atom(initialResponse)))
        } else {
            lines.append(Data(initialResponse.utf8) + crlf)
        }
        if answersFailureChallenge { lines.append(crlf) }
        return IMAPCommand("AUTHENTICATE", arguments,
                           reactiveContinuationLines: lines, isExclusive: true)
    }
}
