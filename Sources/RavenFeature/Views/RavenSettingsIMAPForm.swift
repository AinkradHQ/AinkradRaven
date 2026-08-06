import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The "connect any mailbox" form: address, IMAP and SMTP servers, TLS mode, app
/// password — plus a "Test connection" that reports which of the three things went
/// wrong.
///
/// Its own file rather than more of `RavenSettingsAccounts.swift`, which the two
/// together would have pushed past the repo's 450-line soft limit.
///
/// ## What this view does NOT own
///
/// Every rule — the well-known hosts, the per-mode default ports, the port and host
/// validation, the classification of a failed connect — lives in
/// `IMAPAccountSetup`, as pure functions over values. A rule inside a SwiftUI
/// `body` can only be tested by rendering a view, which in practice means it is not
/// tested; `IMAPAccountSetupTests` calls all of them directly. What is left here is
/// layout, focus and the two `Task`s.
///
/// ## The password
///
/// `password` is `@State` on this view and is passed to `runtime.addIMAPAccount`,
/// which hands it to `host.secrets` through `IMAPAppPasswordStore`. It is cleared
/// the instant the add succeeds — the form does not hold it afterwards, and it is
/// never put into `draft` (which is a plain `Equatable` value that a future edit
/// might reasonably decide to persist as a document).
struct RavenSettingsIMAPForm: View {
    let runtime: RavenRuntime
    /// Called after an account is added, so the accounts list re-reads and this
    /// form collapses.
    let onAdded: () -> Void
    let onCancel: () -> Void

    @Environment(\.ainkradTheme) private var theme

    @State private var draft = IMAPAccountSetup.Draft()
    /// Never written into `draft`, never logged, cleared on success — see above.
    @State private var password = ""
    @State private var issues: [IMAPAccountSetup.FieldIssue] = []
    /// The banner from the last "Test connection" or failed add. `.success` carries
    /// the mailbox count, which is the evidence that the account can actually see
    /// mail rather than merely authenticate.
    @State private var probeResult: ProbeResult?
    @State private var isBusy = false
    /// True once the user has edited a port by hand, after which changing the TLS
    /// mode stops rewriting it. Without this, a user on a non-standard port
    /// (993 → 9930, say) has their entry silently reverted by a mode change.
    @State private var portsAreCustom = false
    /// The same guard for the two host fields. Without it, a user who typed their
    /// own servers and then corrected a typo in an `@fastmail.com` address had both
    /// silently reverted to the preset — the preset overwrote them unconditionally,
    /// while the comment on `applyAddress` claimed it never touched a typed field.
    @State private var hostsAreCustom = false

    private enum ProbeResult: Equatable {
        case success(mailboxes: Int)
        case failure(IMAPAccountSetup.ConnectionFailure)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSectionHeader(title: "Add a mailbox",
                                 subtitle: "IMAP and SMTP, with an app password.")

            AinkradFormRow(title: "Email address",
                           help: "Also the login name, unless you set one below.") {
                AinkradTextField(text: Binding(get: { draft.address },
                                               set: { applyAddress($0) }),
                                 placeholder: "you@example.com")
            }
            inlineMessage(for: .address)

            AinkradFormRow(title: "Encryption",
                           help: "SSL/TLS uses 993 and 465. STARTTLS uses 143 and 587.") {
                AinkradSegmentedPicker(items: IMAPAccountSetup.TLSMode.allCases,
                                       selection: Binding(get: { draft.mode },
                                                          set: { applyMode($0) }),
                                       label: \.title)
            }

            serverRow(title: "IMAP server", hostField: .imapHost, portField: .imapPort,
                      host: $draft.imapHost, port: $draft.imapPort)
            serverRow(title: "SMTP server", hostField: .smtpHost, portField: .smtpPort,
                      host: $draft.smtpHost, port: $draft.smtpPort)

            AinkradFormRow(title: "Username",
                           help: "Leave blank to sign in with the address above.") {
                AinkradTextField(text: $draft.username, placeholder: "Optional")
            }

            AinkradFormRow(title: "App password",
                           help: "Stored in the system Keychain, never in a document.") {
                AinkradSecureField(text: $password, placeholder: "App password")
            }
            inlineMessage(for: .password)

            if let probeResult { banner(for: probeResult) }

            HStack(spacing: AinkradSpacing.sm) {
                AinkradButton(title: "Test Connection", style: .secondary, icon: "bolt.horizontal",
                              isLoading: isBusy, action: { test() })
                    .disabled(isBusy)
                AinkradButton(title: "Add Mailbox", style: .primary, icon: "envelope.badge",
                              isLoading: isBusy, action: { add() })
                    .disabled(isBusy)
                Spacer(minLength: AinkradSpacing.sm)
                AinkradButton(title: "Cancel", style: .ghost, action: onCancel)
                    .disabled(isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AinkradSpacing.xs)
    }

    @ViewBuilder
    private func serverRow(title: String, hostField: IMAPAccountSetup.Field,
                           portField: IMAPAccountSetup.Field,
                           host: Binding<String>, port: Binding<String>) -> some View {
        AinkradFormRow(title: title) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradTextField(text: Binding(get: { host.wrappedValue },
                                               set: { hostsAreCustom = true
                                                      host.wrappedValue = $0 }),
                                 placeholder: "server.example.com")
                AinkradTextField(text: Binding(get: { port.wrappedValue },
                                               set: { portsAreCustom = true
                                                      port.wrappedValue = $0 }),
                                 placeholder: "Port")
                    .frame(width: 90)
            }
        }
        inlineMessage(for: hostField)
        inlineMessage(for: portField)
    }

    /// The refusal for one field, rendered **under that field** — never as a modal.
    /// A dialog would take the message away from the control it is about and force a
    /// dismissal before the user can act on it.
    @ViewBuilder
    private func inlineMessage(for field: IMAPAccountSetup.Field) -> some View {
        if let issue = issues.first(where: { $0.field == field }) {
            HStack(spacing: AinkradSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accentTertiary)
                AinkradCaption(issue.message)
            }
            .padding(.leading, AinkradSpacing.lg)
        }
    }

    @ViewBuilder
    private func banner(for result: ProbeResult) -> some View {
        switch result {
        case .success(let mailboxes):
            AinkradBanner(message: "Connected. The server listed \(mailboxes) "
                                 + "mailbox\(mailboxes == 1 ? "" : "es").",
                          status: .success, onDismiss: { probeResult = nil })
        case .failure(let failure):
            AinkradBanner(message: failure.message, status: .danger,
                          onDismiss: { probeResult = nil })
        }
    }

    // MARK: Defaults

    // Both rules live in `IMAPAccountSetup` as pure functions over a `Draft` —
    // including "do not overwrite what the user typed", which is the part this form
    // previously got wrong. All the view contributes is the two flags recording
    // that a field has been touched.

    private func applyAddress(_ value: String) {
        draft = IMAPAccountSetup.applyingAddress(value, to: draft,
                                                 hostsAreCustom: hostsAreCustom,
                                                 portsAreCustom: portsAreCustom)
    }

    private func applyMode(_ mode: IMAPAccountSetup.TLSMode) {
        draft = IMAPAccountSetup.applyingMode(mode, to: draft, portsAreCustom: portsAreCustom)
    }

    // MARK: Actions

    /// Validates, and returns the settings when the form is complete. A failure
    /// populates `issues` — which is what the inline messages render — and returns
    /// nil, so neither action below can reach the network with a bad port.
    private func validated() -> (address: String, settings: IMAPAccountSettings)? {
        switch IMAPAccountSetup.validate(draft, password: password) {
        case .success(let value):
            issues = []
            return value
        case .failure(let found):
            issues = found.issues
            probeResult = nil
            return nil
        }
    }

    private func test() {
        guard let validated = validated() else { return }
        isBusy = true
        Task {
            switch await runtime.testIMAPConnection(settings: validated.settings,
                                                    password: password) {
            case .success(let mailboxes): probeResult = .success(mailboxes: mailboxes)
            case .failure(let failure): probeResult = .failure(failure)
            }
            isBusy = false
        }
    }

    private func add() {
        guard let validated = validated() else { return }
        isBusy = true
        Task {
            do {
                try await runtime.addIMAPAccount(address: validated.address,
                                                 settings: validated.settings,
                                                 password: password)
                // The form stops holding the credential the moment it is no longer
                // needed. `draft` never held it at all.
                password = ""
                draft = IMAPAccountSetup.Draft()
                probeResult = nil
                onAdded()
            } catch let failure as IMAPAccountSetup.ConnectionFailure {
                probeResult = .failure(failure)
            } catch {
                probeResult = .failure(IMAPAccountSetup.classify(error))
            }
            isBusy = false
        }
    }
}
