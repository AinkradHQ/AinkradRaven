import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Raven's settings surface, in five groups: anything needing attention,
/// accounts, sending, rules, and privacy.
///
/// This was one flat column of five equally-weighted panels — credentials,
/// accounts, sending, rules, outbox — with the dead-letter and needs-review
/// queues, the only things in here that can mean a message did not go out,
/// rendered at the bottom as the least prominent rows on the page. The
/// restructure is about weight: what needs a human comes FIRST and looks
/// urgent, what is used once (OAuth credentials) or rarely (rules, privacy)
/// folds away behind `AinkradDisclosureGroup`, and accounts — the thing people
/// actually open Settings for — is what you land on.
public struct RavenSettingsView: View {
    let runtime: RavenRuntime

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isConnecting = false
    @State private var connectError: String?
    /// Per account, keyed by account id. A single shared string wrote whatever
    /// was typed for one account into whichever row rendered last, which with
    /// several accounts connected means editing account A's signature silently
    /// overwrites B's.
    @State private var signatures: [String: String] = [:]
    /// Bumped after any mutation so this view re-reads `runtime.accounts`,
    /// which is a plain (non-`@Observable`) snapshot method.
    @State private var accountsVersion = 0
    /// The account a sign-out confirmation is currently pending for, if any.
    /// `signOut` is a surgical single-account purge (see `RavenRuntime.
    /// signOut`'s own documentation) — the confirmation must name that
    /// account's actual address, never a bare ambiguous "Sign out?", so the
    /// account is captured here rather than the button acting immediately.
    @State private var pendingSignOut: MailAccount?
    /// Collapsed by default: with credentials baked into the app (the shipped
    /// case) there is nothing in here at all, and even without them it is a
    /// once-per-machine step that should not be the first thing on the page.
    @State private var credentialsExpanded = false
    /// Which account rows have their details (signature, sync history, resync)
    /// open. Collapsed by default so several connected accounts read as a list
    /// of accounts rather than three screens of forms.
    @State private var expandedAccounts: Set<String> = []

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    public init(runtime: RavenRuntime) { self.runtime = runtime }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.lg) {
                OutboxAttentionGroup(runtime: runtime)
                accountsPanel
                credentialsPanel
                SendingSettingsGroup(runtime: runtime)
                RulesSettingsGroup(runtime: runtime)
                PrivacySettingsGroup(runtime: runtime)
            }
            .padding(AinkradSpacing.lg)
        }
        .ainkradPanel()
        .ainkradConfirmDialog(
            isPresented: Binding(
                get: { pendingSignOut != nil },
                set: { if !$0 { pendingSignOut = nil } }),
            title: "Sign out",
            // Names the address it will erase — never a bare "Sign out?".
            message: "Sign out of \(pendingSignOut?.address ?? "this account")? Every local " +
                     "copy of its mail and any queued sends for it will be removed from this " +
                     "device. Other connected accounts are not affected.",
            confirmTitle: "Sign Out",
            isDestructive: true,
            onConfirm: {
                guard let account = pendingSignOut else { return }
                runtime.signOut(account.id)
                accountsVersion += 1
            })
        .onAppear {
            clientID = runtime.savedClientID ?? clientID
            for account in runtime.accounts { signatures[account.id] = account.signature }
        }
        // `runtime.accounts` is a plain snapshot method, not `@Observable`
        // storage, so nothing re-reads it just because `runtime.syncState`
        // changed underneath. This is the push replacement for the old
        // polling: `SyncEngine.onChange` (via `RavenRuntime.mirrorSyncEngineState`)
        // updates `syncState` on every backfill page and on every delta sync,
        // and THIS is what turns each of those pushes into a fresh read of
        // `runtime.accounts` — including the final one, where `state`/
        // `lastSyncedAt`/`lastError` land after a backfill or delta finishes.
        .onChange(of: runtime.syncState) { _, _ in accountsVersion += 1 }
    }

    // MARK: Accounts

    private var accountsPanel: some View {
        AinkradSettingsPanel(
            title: "Accounts",
            hint: "Each connected mailbox, its sync state, and the signature appended to "
                + "messages sent from it."
        ) {
            accountsBody
        }
    }

    @ViewBuilder
    private var accountsBody: some View {
        let accounts = { _ = accountsVersion; return runtime.accounts }()
        if accounts.isEmpty {
            AinkradEmptyState(
                icon: "envelope.badge",
                title: "No accounts connected",
                message: "Connect a Gmail account to start syncing mail into Raven.",
                actionTitle: "Connect Gmail",
                action: { connect() })
                .frame(height: 220)
                .disabled(!canConnect || isConnecting)
        } else {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                ForEach(accounts) { account in
                    accountRow(account)
                }
                AinkradButton(title: "Connect Another Account", style: .secondary,
                              icon: "person.badge.plus", isLoading: isConnecting,
                              action: { connect() })
                    .disabled(!canConnect || isConnecting)
            }
        }
        if let connectError {
            AinkradBanner(message: connectError, status: .danger,
                          onDismiss: { self.connectError = nil })
        }
    }

    /// One account: its address and state on a single always-visible line, with
    /// everything else (signature, sync history, resync, sign-out) behind that
    /// line's own disclosure. Anything that is genuinely WRONG — a sync error, a
    /// truncated backfill, a needs-auth state — stays outside the disclosure,
    /// because a problem the user has to collapse a group to discover is a
    /// problem they will not discover.
    private func accountRow(_ account: MailAccount) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            AinkradDisclosureGroup(
                title: account.address,
                isExpanded: Binding(
                    get: { expandedAccounts.contains(account.id) },
                    set: { isOpen in
                        if isOpen { expandedAccounts.insert(account.id) }
                        else { expandedAccounts.remove(account.id) }
                    })
            ) {
                accountDetail(account)
            }

            HStack(spacing: AinkradSpacing.xs) {
                statusBadge(account)
                if runtime.isReadOnly(accountID: account.id) {
                    AinkradBadge(text: "Read-only", status: .neutral)
                        .ainkradTooltip("An Apple Mail import. It has no transport, so it "
                                        + "cannot send or change labels.")
                }
                if case .backfilling(let threadsSynced) = runtime.syncState(for: account.id) {
                    // Live progress for the backfill `connectAccount`/
                    // `resyncFromScratch` run detached (see
                    // `RavenRuntime.runBackfill`) — without this the row would
                    // sit on the "Syncing" badge with nothing else to look at
                    // for up to a minute.
                    AinkradBadge(text: "\(threadsSynced) synced", status: .neutral)
                }
                Spacer(minLength: AinkradSpacing.sm)
                if let lastSyncedAt = account.lastSyncedAt {
                    Text("Last synced "
                         + lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                        .foregroundStyle(theme.foreground.opacity(0.55))
                }
            }
            .padding(.leading, AinkradSpacing.lg)

            if let lastError = runtime.lastSyncError(for: account.id) ?? account.lastError {
                AinkradBanner(message: lastError, status: .danger)
            }
            if runtime.lastBackfillTruncated(for: account.id) {
                AinkradBanner(message: "The last backfill stopped early (page limit reached). " +
                              "Some older mail in the sync window may be missing.",
                              status: .warning)
            }
        }
        .padding(.vertical, AinkradSpacing.xs)
    }

    @ViewBuilder
    private func accountDetail(_ account: MailAccount) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            // Read-only accounts cannot send, so a signature for one is a field
            // that can never take effect.
            if !runtime.isReadOnly(accountID: account.id) {
                AinkradFormRow(title: "Signature",
                              help: "Appended to every message sent from this account.") {
                    AinkradTextArea(
                        text: Binding(get: { signatures[account.id] ?? account.signature },
                                      set: { signatures[account.id] = $0 }),
                        placeholder: "Signature", minHeight: 60)
                        // Read-modify-write the CURRENT row rather than writing
                        // back `account`, which is a snapshot captured when this
                        // row was rendered: writing that back on every keystroke
                        // clobbered syncCursor/lastSyncedAt/state/lastError with
                        // stale values, silently re-walking (or fully
                        // re-backfilling) the mailbox.
                        .onChange(of: signatures[account.id]) { _, newValue in
                            guard let newValue else { return }
                            runtime.updateSignature(newValue, accountID: account.id)
                        }
                }
            }
            HStack(spacing: AinkradSpacing.sm) {
                AinkradButton(title: "Sync Now", style: .secondary, icon: "arrow.clockwise") {
                    Task {
                        await runtime.syncNow(accountID: account.id)
                        accountsVersion += 1
                    }
                }
                AinkradButton(title: "Resync From Scratch", style: .ghost,
                              icon: "arrow.triangle.2.circlepath") {
                    // Kicks off and returns immediately — see
                    // `RavenRuntime.resyncFromScratch`. Progress reaches this
                    // view via `.onChange(of: runtime.syncState)`, not a poll.
                    runtime.resyncFromScratch(accountID: account.id)
                }
                Spacer(minLength: AinkradSpacing.sm)
                AinkradButton(title: "Sign Out…", style: .danger) {
                    pendingSignOut = account
                }
            }
        }
        .padding(.leading, AinkradSpacing.lg)
    }

    @ViewBuilder
    private func statusBadge(_ account: MailAccount) -> some View {
        switch account.state {
        case .ready: AinkradBadge(text: "Ready", status: .success)
        case .syncing: AinkradBadge(text: "Syncing", status: .neutral)
        case .needsAuth: AinkradBadge(text: "Needs auth", status: .warning)
        case .failed: AinkradBadge(text: "Failed", status: .danger)
        }
    }

    // MARK: Credentials

    /// Whether Connect could possibly work: either credentials are baked into
    /// the app, or the user has previously saved a pair, or they have typed one
    /// in now. Enabled-but-guaranteed-to-fail is worse than disabled.
    private var canConnect: Bool {
        if runtime.isCredentialsBaked { return true }
        if runtime.hasCredentials { return true }
        return !clientID.isEmpty && !clientSecret.isEmpty
    }

    private var credentialsPanel: some View {
        AinkradSettingsPanel(
            title: "Google OAuth client",
            hint: runtime.isCredentialsBaked
                ? "OAuth credentials are built into this app — nothing to configure."
                : "The Desktop OAuth client id and secret from Google Cloud Console. "
                  + "The secret is stored in the system Keychain, never as a plain document."
        ) {
            // Folded away: with baked credentials this group is empty, and
            // without them it is a once-per-machine step.
            AinkradDisclosureGroup(title: runtime.isCredentialsBaked
                                   ? "Built into this app"
                                   : "Client id and secret",
                                   isExpanded: $credentialsExpanded) {
                VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                    // With baked credentials there is nothing for the user to
                    // type — showing the fields anyway would invite them to
                    // (harmlessly, but confusingly) overwrite a working client
                    // id/secret with their own. Manual entry is a fallback for
                    // a developer build with no `Config/oauth-client.json`,
                    // shown ONLY when nothing was baked in.
                    if runtime.isCredentialsBaked {
                        Text("This build ships with its own Google OAuth client, so there is "
                             + "nothing to enter here.")
                            .font(AinkradFontResolver.font(.caption, typography: typo))
                            .foregroundStyle(theme.foreground.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        AinkradFormRow(title: "Client ID", controlWidth: 340) {
                            AinkradTextField(text: $clientID,
                                            placeholder: "xxxx.apps.googleusercontent.com")
                        }
                        AinkradFormRow(title: "Client secret", controlWidth: 340) {
                            AinkradSecureField(text: $clientSecret, placeholder: "Client secret")
                        }
                        if !runtime.hasCredentials && !canConnect {
                            AinkradBanner(message: "Enter a Gmail OAuth client id and secret to "
                                          + "enable Connect.", status: .warning)
                        }
                    }
                }
            }
        }
    }

    private func connect() {
        if !runtime.isCredentialsBaked && (!clientSecret.isEmpty || !runtime.hasCredentials) {
            guard !clientSecret.isEmpty else {
                connectError = "Enter the client secret to save new credentials."
                credentialsExpanded = true
                return
            }
            runtime.saveCredentials(clientID: clientID, clientSecret: clientSecret)
            clientSecret = ""
        }
        isConnecting = true
        Task {
            do {
                try await runtime.connectAccount(onAuthorizationURL: { url in
                    // `authorize` already opens this in the default browser;
                    // logging it too covers the case (a bare command-line
                    // host, or a browser that fails to focus) where that
                    // doesn't visibly happen. The URL carries no secret — see
                    // `GmailAuth.authorize`'s own documentation of this point.
                    //
                    // Goes to `host.log`, not `print()`: a shipped plugin's
                    // stdout is not somewhere the user or the host can read.
                    // This callback is `@Sendable` and arrives off the main
                    // actor, hence the hop.
                    Task { @MainActor in
                        runtime.log("Raven: open this URL to finish connecting Gmail: \(url)")
                    }
                })
                accountsVersion += 1
                for account in runtime.accounts where signatures[account.id] == nil {
                    signatures[account.id] = account.signature
                }
            } catch {
                connectError = "Could not connect: \(error)"
            }
            isConnecting = false
        }
    }
}
