import Foundation
import Security

/// The SMTP envelope: who the message is from, and every address the server is
/// asked to deliver it to.
///
/// A separate value from `OutgoingMessage` on purpose. The envelope is *not* the
/// headers — this is the whole reason a `Bcc` recipient can receive a message
/// without any recipient seeing that they did.
struct SMTPEnvelope: Equatable, Sendable {
    let sender: String
    /// `to` + `cc` + `bcc`, in that order, de-duplicated. Order is fixed rather
    /// than incidental so a wire assertion can compare the whole `RCPT TO`
    /// sequence.
    let recipients: [String]
}

/// Turns an `OutgoingMessage` into an SMTP submission: envelope, message data,
/// dot-stuffing, and the one place a message id may be reported.
///
/// ## Bcc: the exact opposite of Gmail's rule
///
/// This is the reason `RFC822Builder.includeBccHeader` has no default value.
/// Gmail's `messages/send` takes the whole RFC822 message and derives the
/// envelope from its headers, so the `Bcc:` header **must be present** there or
/// the blind recipient is silently dropped — `GmailRFC822` passes `true` and
/// documents why. SMTP is the other way round: the recipients are named in the
/// envelope (`RCPT TO`), and a transmitted `Bcc:` header would be delivered to
/// everyone, disclosing the private distribution list. So this file passes
/// `false`, and puts the bcc addresses in the envelope instead. Both halves are
/// asserted together in `SMTPSubmitterTests`; asserting only one of them would
/// pass for an implementation that simply dropped the bcc recipient entirely.
struct SMTPSubmitter: Sendable {
    let endpoint: MailTransportEndpoint
    /// The envelope sender — the authenticated account's own address.
    let sender: String
    let credential: IMAPCredential
    let clientDomain: String
    /// Builds the transport for `endpoint`. Injected so tests submit over
    /// `ScriptedTransport`; production passes `NetworkTransport.init`.
    let makeTransport: @Sendable (MailTransportEndpoint) -> any MailTransport
    /// S/MIME identity lookup, threaded straight through to `RFC822Builder`. The
    /// default finds nothing, which is the ordinary unsigned case.
    let identityLookup: @Sendable (String) -> SecIdentity?

    init(endpoint: MailTransportEndpoint,
         sender: String,
         credential: IMAPCredential,
         clientDomain: String = "[127.0.0.1]",
         makeTransport: @escaping @Sendable (MailTransportEndpoint) -> any MailTransport
            = { NetworkTransport(endpoint: $0) },
         identityLookup: @escaping @Sendable (String) -> SecIdentity? = { _ in nil }) {
        self.endpoint = endpoint
        self.sender = sender
        self.credential = credential
        self.clientDomain = clientDomain
        self.makeTransport = makeTransport
        self.identityLookup = identityLookup
    }

    // MARK: - Pure assembly

    /// The envelope for a message. Every recipient class is included — `bcc` is
    /// not special here, which is precisely how a blind recipient gets the mail.
    /// De-duplicated because an address in both `to` and `bcc` would otherwise
    /// get two `RCPT TO` commands and, on some servers, two copies.
    static func envelope(for message: OutgoingMessage, sender: String) -> SMTPEnvelope {
        var seen = Set<String>()
        var recipients: [String] = []
        for address in message.to + message.cc + message.bcc {
            let email = address.email
            guard !email.isEmpty, seen.insert(email.lowercased()).inserted else { continue }
            recipients.append(email)
        }
        return SMTPEnvelope(sender: sender, recipients: recipients)
    }

    /// The complete RFC 822 message, with **no `Bcc:` header** — see this type's
    /// documentation for why that is the opposite of Gmail's requirement.
    func messageData(for message: OutgoingMessage) -> String {
        let lookup = identityLookup
        return RFC822Builder.message(message, includeBccHeader: false,
                                     identityLookup: { lookup($0) })
    }

    /// Transparency, RFC 5321 §4.5.2: a line whose first character is `.` gets a
    /// second `.` prepended, because a bare `.` alone on a line is the
    /// end-of-message marker. Without this, a body containing
    /// ```
    /// .
    /// ```
    /// truncates the message there and the remainder is interpreted as SMTP
    /// commands.
    ///
    /// Also guarantees the result ends in CRLF, so `SMTPSession.finishData` can
    /// append `.CRLF` and produce the exact `CRLF.CRLF` terminator.
    ///
    /// Operates on CRLF-delimited text — which is what `RFC822Builder` emits, and
    /// a lone LF here would already be a MIME bug rather than something to paper
    /// over, so lines are split on CRLF only.
    ///
    /// ## Recorded plainly: today this is defensive code
    ///
    /// **No message `RFC822Builder` can currently produce contains a stuffable
    /// line**, so nothing in the SMTP suite reaches this function's stuffing branch
    /// via the wire — only via `SMTPSubmitterAssemblyTests.dotStuffing`, as a pure
    /// function. Every line of an assembled message is one of: a header field line
    /// (which begins with its field name), an RFC 2047 fold continuation (which
    /// begins with a space), a blank separator, a `--raven-<uuid>` boundary, or a
    /// `MIMEHeader.base64Body` line — and the base64 alphabet contains no `.`. Both
    /// text parts and every attachment declare `Content-Transfer-Encoding: base64`
    /// and are actually encoded, so a user's `.` on its own line cannot survive to
    /// the wire as one.
    ///
    /// That is a property of today's MIME assembly, not of SMTP. The moment any
    /// part is emitted `7bit`/`8bit` — a `quoted-printable` or plain-text body, an
    /// inline part passed through verbatim — the stuffing branch becomes live and
    /// the failure it prevents is a silently truncated message. It stays, and it
    /// stays unconditional, for that reason.
    static func dotStuffed(_ message: String) -> Data {
        var lines = message.components(separatedBy: "\r\n")
        // A trailing CRLF produces a final empty component; drop it so the join
        // below does not add a blank line, then re-add exactly one CRLF at the end.
        if lines.last?.isEmpty == true { lines.removeLast() }
        let stuffed = lines.map { $0.hasPrefix(".") ? "." + $0 : $0 }
        return Data((stuffed.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: - Submission

    /// Submits one message and returns an identifier for it.
    ///
    /// **At-most-once.** An id is returned only after a `250` on end-of-data. Every
    /// earlier failure throws with nothing transmitted; a failure *after* the data
    /// was written throws `SMTPSessionError.outcomeUnknown`, which maps to
    /// `MailError.sendOutcomeUnknown` and which `Outbox.drain` holds for review
    /// instead of retrying. Nothing in this function infers success from the
    /// absence of an error.
    ///
    /// - Returns: the text of the accepting `250`, which for most servers is a
    ///   queue id. SMTP has no message id to return — the `Message-ID` header is
    ///   assigned by the submission server when the message does not carry one,
    ///   and the protocol never tells the client what it chose. So this is the only
    ///   identifier the wire offers, and `"accepted"` stands in when the server
    ///   sends a bare `250`.
    func submit(_ message: OutgoingMessage) async throws -> String {
        let session = SMTPSession(transport: makeTransport(endpoint),
                                  security: endpoint.tls,
                                  clientDomain: clientDomain)
        do {
            try await session.connect()
            if endpoint.tls == .explicit { try await session.upgradeToTLS() }
            try await session.authenticate(credential)
            let envelope = Self.envelope(for: message, sender: sender)
            try await session.mailFrom(envelope.sender)
            for recipient in envelope.recipients {
                try await session.rcptTo(recipient)
            }
            try await session.beginData()
            let reply = try await session.finishData(Self.dotStuffed(messageData(for: message)))
            await session.quit()
            let id = reply.text.trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? "accepted" : id
        } catch let error as SMTPSessionError {
            // The transport is closed on every path — a submission that failed
            // mid-dialogue must not leave a socket open — but `quit()` cannot
            // change what did or did not go out, so the failure itself is
            // untouched by it.
            await session.quit()
            // Translated at this boundary, and only here: `Outbox` must not have to
            // know what SMTP is, and the whole 4xx/5xx/unknown distinction is
            // worthless if it does not arrive in the vocabulary the drain
            // actually branches on. `SMTPSessionError.mailError` is that mapping;
            // callers wanting the protocol-level detail use `SMTPSession` directly.
            throw error.mailError
        } catch {
            await session.quit()
            throw error
        }
    }
}
