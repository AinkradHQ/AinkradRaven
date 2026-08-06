import Foundation

/// Everything about adding an IMAP account that is a **pure function of what the
/// user typed** — the well-known host/port defaults, the boundary validation, and
/// the classification of a failed connection attempt.
///
/// Kept out of the view on purpose. A rule that lives in a SwiftUI `body` can only
/// be tested by rendering, which in practice means it is not tested at all; every
/// rule here is a static function over values, and `IMAPAccountSetupTests` calls
/// them directly. The view (`RavenSettingsIMAPForm`) contributes layout and nothing
/// else.
enum IMAPAccountSetup {

    // MARK: - Defaults

    /// The two shapes a mail server offers, in the user's words rather than the
    /// transport's. This is what the form's picker is bound to.
    enum TLSMode: String, CaseIterable, Sendable {
        /// TLS from the first byte: IMAP 993, submission 465.
        case implicit
        /// Plaintext connect, then a `STARTTLS` upgrade: IMAP 143, submission 587.
        ///
        /// Offered — rather than quietly omitted — because Task 15b made
        /// `NetworkTransport.startTLS()` a real upgrade via `STARTTLSFramer`. Before
        /// that it could only throw, and an option that cannot work is worse than no
        /// option. There is still no plaintext choice, and there will not be one.
        case startTLS

        var transport: MailTransportTLS { self == .implicit ? .implicit : .explicit }

        var title: String { self == .implicit ? "SSL/TLS" : "STARTTLS" }

        /// The default IMAP port for this mode.
        var defaultIMAPPort: UInt16 { self == .implicit ? 993 : 143 }
        /// The default submission port for this mode.
        var defaultSMTPPort: UInt16 { self == .implicit ? 465 : 587 }
    }

    /// A well-known provider's server names, matched on the address domain.
    struct HostPreset: Equatable, Sendable {
        let imapHost: String
        let smtpHost: String
    }

    /// Domain → servers, for the handful of providers that account for most
    /// non-Gmail-OAuth mailboxes. **Names only, never ports**: the port belongs to
    /// the TLS mode, and baking a port in here would make a preset silently
    /// contradict the picker the user just moved.
    private static let presets: [String: HostPreset] = [
        "icloud.com": HostPreset(imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com"),
        "me.com": HostPreset(imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com"),
        "mac.com": HostPreset(imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com"),
        "fastmail.com": HostPreset(imapHost: "imap.fastmail.com", smtpHost: "smtp.fastmail.com"),
        "gmail.com": HostPreset(imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com"),
        "googlemail.com": HostPreset(imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com"),
        "outlook.com": HostPreset(imapHost: "outlook.office365.com",
                                  smtpHost: "smtp.office365.com"),
        "hotmail.com": HostPreset(imapHost: "outlook.office365.com",
                                  smtpHost: "smtp.office365.com"),
        "yahoo.com": HostPreset(imapHost: "imap.mail.yahoo.com",
                                smtpHost: "smtp.mail.yahoo.com"),
    ]

    /// The known servers for an address, or `nil` for a domain this build has never
    /// heard of — which is the *expected* answer for the self-hosted mailboxes this
    /// whole feature exists for, and is why nothing downstream treats it as an error.
    static func preset(forAddress address: String) -> HostPreset? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
            .trimmingCharacters(in: .whitespaces).lowercased()
        return presets[domain]
    }

    // MARK: - Applying defaults to a draft

    /// A new address, with the servers and ports it implies filled in — but only
    /// where the user has not supplied their own.
    ///
    /// A pure function rather than three lines in the view's setter, because the
    /// rule it encodes is the one this form gets wrong in the way users notice:
    /// correcting a typo in an `@fastmail.com` address must not silently revert the
    /// custom servers typed underneath it. `hostsAreCustom`/`portsAreCustom` are the
    /// view's record of "the user has touched this"; everything else about the
    /// decision is here, where a test can reach it.
    static func applyingAddress(_ address: String, to draft: Draft,
                                hostsAreCustom: Bool, portsAreCustom: Bool) -> Draft {
        var updated = draft
        updated.address = address
        // An unknown domain — the self-hosted case this feature exists for — leaves
        // both host fields exactly as they are. Clearing them would be worse than
        // offering nothing.
        guard !hostsAreCustom, let preset = preset(forAddress: address) else { return updated }
        updated.imapHost = preset.imapHost
        updated.smtpHost = preset.smtpHost
        if !portsAreCustom { updated = applyingDefaultPorts(to: updated) }
        return updated
    }

    /// A new TLS mode, with the ports it implies — again, only when the user has
    /// not typed their own. A mailbox on 9930 must survive a mode change.
    static func applyingMode(_ mode: TLSMode, to draft: Draft,
                             portsAreCustom: Bool) -> Draft {
        var updated = draft
        updated.mode = mode
        return portsAreCustom ? updated : applyingDefaultPorts(to: updated)
    }

    static func applyingDefaultPorts(to draft: Draft) -> Draft {
        var updated = draft
        updated.imapPort = String(draft.mode.defaultIMAPPort)
        updated.smtpPort = String(draft.mode.defaultSMTPPort)
        return updated
    }

    // MARK: - Validation

    /// Which field an inline message belongs beside. The form renders each one
    /// under its own control, so a refusal never becomes a modal.
    enum Field: String, Equatable, Sendable, CaseIterable {
        case address, imapHost, imapPort, smtpHost, smtpPort, password
    }

    /// One refusal, already worded for the user.
    struct FieldIssue: Equatable, Sendable {
        let field: Field
        let message: String
    }

    /// Every refusal a draft produced. A type rather than a bare array so it can be
    /// thrown as well as returned — the add path needs both shapes.
    struct ValidationFailure: Error, Equatable, Sendable {
        let issues: [FieldIssue]
    }

    /// The port range a TCP client may actually connect to.
    ///
    /// `0` is excluded deliberately and is the reason this is a range check rather
    /// than a `UInt16(_:)` parse: `UInt16("0")` succeeds, and port 0 means "let the
    /// kernel choose" to a *listener* — to a connect it is simply invalid, and
    /// `NWEndpoint.Port(rawValue: 0)` would take it. Typing `0` must be refused at
    /// the boundary, not discovered as an unexplained connect failure.
    static func port(from text: String) -> UInt16? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    /// A host is refused when it is empty or contains whitespace. Nothing stricter:
    /// a hostname, an IPv4 literal and a `.local` name are all legitimate here, and
    /// a regex that let one of them through and not another would refuse a server
    /// the user can reach.
    private static func hostIssue(_ value: String, field: Field, label: String) -> FieldIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return FieldIssue(field: field, message: "Enter the \(label).") }
        if trimmed.contains(where: \.isWhitespace) {
            return FieldIssue(field: field, message: "A server name cannot contain spaces.")
        }
        return nil
    }

    /// What the form holds. Ports are `String` because that is what a text field
    /// produces, and turning "80x" into a number is exactly the boundary check.
    struct Draft: Equatable, Sendable {
        var address: String = ""
        var imapHost: String = ""
        var imapPort: String = ""
        var smtpHost: String = ""
        var smtpPort: String = ""
        var mode: TLSMode = .implicit
        /// The username to log in as. Empty means "the same as the address", which
        /// is what every provider in `presets` expects.
        var username: String = ""

        var effectiveUsername: String {
            let trimmed = username.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? address.trimmingCharacters(in: .whitespaces) : trimmed
        }
    }

    /// Validates a draft plus the typed password, and returns either the settings to
    /// persist or **every** issue found.
    ///
    /// Every issue, not the first: a form that reveals one problem per submit makes
    /// the user round-trip four times to fix four fields.
    ///
    /// The password is passed in and validated here but is deliberately NOT part of
    /// `Draft` and NOT part of the returned settings — it goes to `host.secrets`
    /// alone. This function returns it to no one; the caller already has it.
    static func validate(_ draft: Draft, password: String)
        -> Result<(address: String, settings: IMAPAccountSettings), ValidationFailure> {
        var issues: [FieldIssue] = []

        let address = draft.address.trimmingCharacters(in: .whitespaces)
        if address.isEmpty {
            issues.append(FieldIssue(field: .address, message: "Enter your email address."))
        } else if !address.contains("@") || address.hasPrefix("@") || address.hasSuffix("@") {
            issues.append(FieldIssue(field: .address,
                                     message: "That does not look like an email address."))
        }

        if let issue = hostIssue(draft.imapHost, field: .imapHost, label: "IMAP server") {
            issues.append(issue)
        }
        if let issue = hostIssue(draft.smtpHost, field: .smtpHost, label: "SMTP server") {
            issues.append(issue)
        }

        let imapPort = port(from: draft.imapPort)
        if imapPort == nil {
            issues.append(FieldIssue(field: .imapPort,
                                     message: "Enter a port between 1 and 65535."))
        }
        let smtpPort = port(from: draft.smtpPort)
        if smtpPort == nil {
            issues.append(FieldIssue(field: .smtpPort,
                                     message: "Enter a port between 1 and 65535."))
        }

        if password.isEmpty {
            issues.append(FieldIssue(field: .password,
                                     message: "Enter this account's app password."))
        }

        guard issues.isEmpty, let imapPort, let smtpPort else {
            return .failure(ValidationFailure(issues: issues))
        }
        let settings = IMAPAccountSettings(
            host: draft.imapHost.trimmingCharacters(in: .whitespaces),
            port: imapPort,
            username: draft.effectiveUsername,
            tls: draft.mode.transport,
            smtp: SMTPAccountSettings(host: draft.smtpHost.trimmingCharacters(in: .whitespaces),
                                      port: smtpPort, tls: draft.mode.transport))
        return .success((address, settings))
    }

    // MARK: - Typed connection failure

    /// Why "Test connection" failed, in the three categories that lead to three
    /// different user actions: fix the password, fix the TLS mode, fix the server.
    ///
    /// A single error string is what this replaces, and the reason is that the three
    /// cases are indistinguishable in prose written by a server. `"[AUTHENTICATIONFAILED]
    /// Invalid credentials"` and `"connection refused"` both render as "it did not
    /// work"; only the category tells the user which of the four fields above to go
    /// back to.
    ///
    /// ## What this genuinely cannot distinguish, stated rather than implied
    ///
    /// - A server that **drops the connection** on a bad password (some do, rather
    ///   than answering `NO`) is reported as `.host`. The transport saw a close and
    ///   there is nothing in the bytes that says why.
    /// - Within `.host`, a DNS failure, a refused connection and a timeout are one
    ///   case. `Network.framework` distinguishes them, but the remedy — check the
    ///   server name and port — is the same, so splitting them would add categories
    ///   without adding actions.
    /// - Within `.tls`, a certificate the system rejects and a protocol-version
    ///   mismatch are one case.
    /// - **Choosing SSL/TLS against a STARTTLS-only port** usually surfaces as
    ///   `.tls` (the handshake finds no peer speaking TLS) but can surface as
    ///   `.host` if the server closes first. The message for `.tls` therefore names
    ///   the mode as a thing to check.
    enum ConnectionFailure: Error, Equatable, Sendable {
        /// The server could not be reached at all.
        case host(String)
        /// A connection was made but could not be secured.
        case tls(String)
        /// The server was reached and secured, and refused the credential.
        case auth(String)
        /// The server was reached, secured **and signed in to**, and then refused a
        /// command — in practice the `LIST "" "*"` that `openSession` performs.
        ///
        /// A fourth category rather than folding into `.auth`, because folding it in
        /// is a wrong answer the user acts on: a server that refuses the wildcard
        /// `LIST`, or has a namespace prefix, would be reported as "check the
        /// username and app password", sending the user to rotate a credential that
        /// just worked. Nothing in the four fields of the form can fix this one, and
        /// the message says so instead of naming a field to go correct.
        case server(String)

        /// One sentence for the banner. Never carries a credential: every
        /// interpolated string below is either this build's own prose or
        /// server-authored text (`IMAPAuthError` is documented to hold only that).
        var message: String {
            switch self {
            case .host(let detail):
                return "Could not reach the server. Check the server name and port. (\(detail))"
            case .tls(let detail):
                return "Could not secure the connection. Check the encryption mode "
                     + "for this port. (\(detail))"
            case .auth(let detail):
                return "The server refused the sign-in. Check the username and app "
                     + "password. (\(detail))"
            case .server(let detail):
                // Deliberately does NOT say "signed in": two of the five routes here
                // are pre-auth `CAPABILITY` failures, so claiming the credential was
                // accepted would be wrong in those cases. What every route DOES share
                // is that the server answered and refused a command carrying no
                // credential, so there is no field on this form to go and correct.
                //
                // The wording also avoids the word "password" entirely, which
                // `categoriesAreDistinguishableToTheUser` asserts: even a sentence
                // that mentions it only to exonerate it sends the reader to the one
                // control that is not the problem.
                return "The server refused a command this account needs, and no "
                     + "detail on this form will change that. (\(detail))"
            }
        }

        /// Which field the banner should send the user back to, or `nil` when no
        /// field on this form can fix the failure — `.server` is exactly that case,
        /// and pointing at one anyway would be a wrong instruction rather than a
        /// missing one.
        var field: Field? {
            switch self {
            case .host: return .imapHost
            case .tls: return .imapPort
            case .auth: return .password
            case .server: return nil
            }
        }
    }

    /// Sorts a thrown error into one of the three categories.
    ///
    /// The default is `.host`, and that choice is deliberate rather than arbitrary:
    /// an unclassified failure happened somewhere in establishing the connection,
    /// and pointing at the credential for something that may never have reached the
    /// server would send the user to reset a password that was fine.
    static func classify(_ error: any Error) -> ConnectionFailure {
        switch error {
        case let error as IMAPAuthError:
            switch error {
            case .rejected(let text):
                return .auth(text)
            case .mechanismUnavailable(let mechanism):
                return .auth("the server does not offer \(mechanism)")
            case .plaintextLoginDisabled:
                return .auth("the server has disabled password sign-in on this connection")
            case .startTLSUnadvertised:
                return .tls("the server did not offer STARTTLS")
            case .explicitTLSUnsupported:
                return .tls("this connection cannot be upgraded to TLS")
            }
        case let error as MailTransportError:
            return classify(transport: error)
        case let error as IMAPSessionError:
            switch error {
            case .transportFailure(let inner):
                return classify(transport: inner)
            case .commandFailed(_, _, let text):
                // NOT `.auth`, and the reason is structural rather than a judgement
                // call: `IMAPAuthenticator.authenticate` catches `commandFailed` on
                // the credential-bearing command and rethrows it as
                // `IMAPAuthError.rejected` — which the case above already handles.
                // So a bare `commandFailed` reaching here cannot be the sign-in; on
                // the probe path it is the `CAPABILITY` or the `LIST "" "*"`. This
                // is how "which command failed" is decided without parsing a tag:
                // the authenticator has already labelled its own.
                return .server(text)
            default:
                return .host("\(error)")
            }
        default:
            return .host("\(error)")
        }
    }

    private static func classify(transport error: MailTransportError) -> ConnectionFailure {
        switch error {
        case .tlsFailed(let detail): return .tls(detail)
        case .tlsUpgradeUnsupported: return .tls("this connection cannot be upgraded to TLS")
        case .connectionFailed(let detail): return .host(detail)
        case .notConnected: return .host("the connection was never established")
        case .closed: return .host("the server closed the connection")
        default: return .host("\(error)")
        }
    }
}
