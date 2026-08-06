import Foundation

/// An authenticated `IMAPSession` plus the account's `LIST`ed mailboxes.
///
/// The pair travels together because nothing above the transport can do useful
/// work with only one of them: every command needs the session and every *mailbox
/// name* — the thing `SELECT`, `UID MOVE` and the vocabulary are all written in —
/// needs the directory.
struct IMAPWorkingSession: Sendable {
    let session: IMAPSession
    let directory: IMAPMailboxDirectory
}

/// A session borrowed for the duration of ONE provider operation, plus the action
/// that gives it back.
///
/// The lease exists because the acquire had no matching release. `openSession`
/// connects, authenticates and `LIST`s, and every provider method called it — once
/// per `fetchThreads` page, per `fetchBody`, per `fetchAttachment`, per
/// `applyLabels` — while nothing anywhere called `IMAPSession.close()`. Nothing
/// leaked unboundedly, because `IMAPSession`'s read loop hits its 60-second
/// `readTimeout` and tears the transport down, but "eventually, after a minute" is
/// not a release: a backfill paging ten times inside that minute holds ten
/// authenticated connections to one account, real servers cap concurrent IMAP
/// connections per user (commonly 10–20), and the cap arrives as a connect/auth
/// failure on an unrelated later operation with nothing pointing at the cause.
///
/// Pairing the two in ONE value is what makes the release impossible to forget:
/// `IMAPProvider.withSession` is the only way to reach a session, and it releases on
/// both the success and the throwing path. It also keeps the provider out of the
/// business of deciding *whether* it owns the session — production hands over a
/// lease that logs out and closes, a scripted test hands over one that does not, and
/// neither needs a flag on the provider.
struct IMAPSessionLease: Sendable {
    let working: IMAPWorkingSession
    /// Called exactly once, by `withSession`, when the operation finishes — however
    /// it finishes.
    let release: @Sendable () async -> Void
}

/// Where an account's *submission* server lives. Separate from the IMAP half
/// because they are genuinely different servers on genuinely different ports —
/// `imap.gmail.com:993` and `smtp.gmail.com:465` — and defaulting one from the
/// other would aim a submission at a host that does not speak SMTP.
struct SMTPAccountSettings: Codable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let tls: MailTransportTLS
}

/// Where an IMAP account's server lives. Not a credential: the app password/OAuth
/// token is an `IMAPCredential` and reaches `host.secrets` only.
///
/// ## Decoding is lenient in BOTH directions, and that is load-bearing
///
/// `tls` and `smtp` arrived with Task 16, so a document written before it has
/// neither — but the harder case is the other direction. `MailTransportTLS`'s
/// synthesised decode is **strict**: an unrecognised raw string (`"requireTLS13"`
/// from some later build, a hand-edited document) *throws*, and `decodeIfPresent`
/// does not soften that — it returns `nil` only for a missing or null key. A throw
/// here is not a local failure: `ProviderFactory.makeIMAPProvider` decodes with
/// `try?`, so the whole settings document reads as absent, the account cannot be
/// built, and the user is left looking at a mailbox row that will not connect and
/// says nothing about why. That is the one-bad-value-strands-the-account shape
/// `ProviderKind.unsupported` and `MailAccount.State` were each already fixed for.
///
/// So both fields are read with `try?` and fall back, and the two fallbacks are
/// deliberately asymmetric:
///
/// - `tls` falls back to `.implicit` — for an absent key because that is exactly
///   what `openSession` hardcoded before the field existed, and for an
///   *unrecognised* one because implicit is the conservative direction: TLS from
///   the first byte. Falling back to `.explicit` would turn an unreadable value
///   into a plaintext connect followed by an upgrade, and `.implicit` cannot become
///   a downgrade no matter what the unknown value meant.
/// - `smtp` falls back to **`nil`**, not to the IMAP host with a guessed port.
///   There is no derivation that is right in general (`imap.` is not `smtp.`, 993
///   is not 465), so an absent — or unreadable — submission server is refused by
///   `IMAPProvider.send` rather than turned into a connection to a host that never
///   agreed to relay mail. Reading still works either way, which is the point:
///   the account is never stranded, only its send path is refused, by name.
struct IMAPAccountSettings: Codable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let username: String
    let tls: MailTransportTLS
    /// `nil` when this account has no configured submission server — see above.
    let smtp: SMTPAccountSettings?

    init(host: String, port: UInt16 = 993, username: String,
         tls: MailTransportTLS = .implicit, smtp: SMTPAccountSettings? = nil) {
        self.host = host; self.port = port; self.username = username
        self.tls = tls; self.smtp = smtp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        // `try?`, not `decodeIfPresent`: the difference is an unrecognised raw
        // value, which `decodeIfPresent` throws on. See this type's documentation.
        tls = (try? container.decode(MailTransportTLS.self, forKey: .tls)) ?? .implicit
        smtp = try? container.decode(SMTPAccountSettings.self, forKey: .smtp)
    }

    /// The transport endpoint for the IMAP half.
    var endpoint: MailTransportEndpoint {
        MailTransportEndpoint(host: host, port: port, tls: tls)
    }

    /// The transport endpoint for the submission half, or `nil` when none is
    /// configured.
    var smtpEndpoint: MailTransportEndpoint? {
        smtp.map { MailTransportEndpoint(host: $0.host, port: $0.port, tls: $0.tls) }
    }
}

/// How `IMAPProvider` gets a session and — the half that was missing — gives it
/// back.
///
/// Split from `IMAPProvider.swift` for the repo's line limit, along a real seam: this
/// file is entirely about the LIFETIME of a connection (open it, borrow it, log out,
/// close it) and knows nothing about mailboxes, threads or UIDs, while the other file
/// never touches a socket's lifetime because `withSession` is the only way it can
/// reach a session at all.
extension IMAPProvider {

    /// Runs `body` with a borrowed session and releases it afterwards — **on the
    /// throwing path as well**, which is the half that matters.
    ///
    /// Written out rather than expressed with `defer`, because `defer` cannot
    /// `await`: releasing a session is asynchronous (it sends `LOGOUT` and closes a
    /// transport), so the language offers no scope-exit hook here and the two paths
    /// have to be spelled out. A failed operation therefore cannot leave a
    /// half-authenticated connection behind for the next one to trip over — the
    /// production release closes the connection outright rather than returning it to
    /// a pool.
    /// `sending`, not `@Sendable`: an actor-isolated caller — `IMAPIdleWatcher`, which
    /// holds one session for up to 29 minutes — necessarily closes over its own
    /// isolation, and a `@Sendable` closure could not touch it at all. `sending`
    /// transfers the closure once, which is exactly the lifetime it has here: it is
    /// called and awaited before `withSession` returns, and never stored.
    func withSession<T: Sendable>(
        _ body: sending (IMAPWorkingSession) async throws -> T) async throws -> T {
        let lease = try await acquire()
        do {
            let value = try await body(lease.working)
            await lease.release()
            return value
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Ends a session the way a client should: `LOGOUT`, then close. The production
    /// `release`.
    ///
    /// `LOGOUT` is best-effort (`try?`) and close is unconditional. That order of
    /// concerns is deliberate: a server that will not answer `LOGOUT` — or a session
    /// already torn down by the operation that just failed — must not stop the socket
    /// from being closed, which is the part that actually returns the connection slot.
    /// Skipping `LOGOUT` entirely would work too, but it leaves the server to notice
    /// the drop by timeout, which is exactly the delay this whole mechanism exists to
    /// remove.
    static func closeSession(_ working: IMAPWorkingSession) async {
        _ = try? await working.session.execute(IMAPCommand("LOGOUT", isExclusive: true))
        await working.session.close()
    }

    /// Connects, authenticates, and `LIST`s — the production acquire.
    ///
    /// The TLS mode is **the user's**, taken from `settings.tls`, since Task 16 —
    /// this was hardcoded `.implicit` while Task 15b's `STARTTLSFramer` did not
    /// exist and `NetworkTransport.startTLS()` could only throw. It is not a
    /// weakening: `.explicit` routes through `IMAPAuthenticator.authenticate`,
    /// whose first act is the `STARTTLS` upgrade, and which refuses outright if the
    /// server never advertised it or the handshake fails. There is no branch on
    /// either mode that writes a credential in the clear.
    ///
    /// The `LIST "" "*"` happens here, once per session, because every later call is
    /// written in mailbox names and a directory fetched per operation would cost a
    /// round trip on each of them.
    static func openSession(settings: IMAPAccountSettings,
                           credential: IMAPCredential) async throws -> IMAPWorkingSession {
        let transport = NetworkTransport(endpoint: settings.endpoint)
        let session = IMAPSession(transport: transport)
        let greeting = try await session.connect()
        try await IMAPAuthenticator(session: session, security: settings.tls)
            .authenticate(credential, greeting: greeting)
        let listed = try await session.execute(
            IMAPCommand("LIST", [.quoted(""), .quoted("*")], isExclusive: true))
        return IMAPWorkingSession(
            session: session,
            directory: IMAPMailboxDirectory(untagged: listed.untagged))
    }

}
