import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Accounts / Settings surface: OAuth client credentials, connect flow,
/// per-account sync status (including the backfill-truncated flag, which is
/// NOT part of `SyncState` and would otherwise go unseen), a signature field,
/// and the outbox's dead-letter and needs-review queues with a way to act on
/// each.
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

    public init(runtime: RavenRuntime) { self.runtime = runtime }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.lg) {
                credentialsPanel
                accountsPanel
                outboxPanel
            }
            .padding(AinkradSpacing.lg)
        }
        .ainkradPanel()
        .ainkradConfirmDialog(
            isPresented: Binding(
                get: { pendingSignOut != nil },
                set: { if !$0 { pendingSignOut = nil } }),
            title: "Sign out",
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

    // MARK: Credentials

    private var credentialsPanel: some View {
        AinkradSettingsPanel(
            title: "Gmail account",
            hint: runtime.isCredentialsBaked
                ? "OAuth credentials are built into this app — just connect."
                : "The Desktop OAuth client id and secret from Google Cloud Console. " +
                  "The secret is stored in the system Keychain, never as a plain document."
        ) {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                // With baked credentials there is nothing for the user to
                // type — showing the fields anyway would invite them to
                // (harmlessly, but confusingly) overwrite a working client
                // id/secret with their own. Manual entry is a fallback for a
                // developer build with no `Config/oauth-client.json`, shown
                // ONLY when nothing was baked in.
                if !runtime.isCredentialsBaked {
                    AinkradFormRow(title: "Client ID") {
                        AinkradTextField(text: $clientID, placeholder: "xxxx.apps.googleusercontent.com")
                            .frame(width: 340)
                    }
                    AinkradFormRow(title: "Client secret") {
                        AinkradSecureField(text: $clientSecret, placeholder: "Client secret")
                            .frame(width: 340)
                    }
                }
                if let connectError {
                    AinkradBanner(message: connectError, status: .danger,
                                  onDismiss: { self.connectError = nil })
                }
                if !runtime.isCredentialsBaked && !runtime.hasCredentials {
                    // Neither baked nor previously saved: there is no way
                    // this button could work yet. Disabled with a clear
                    // reason rather than enabled-but-guaranteed-to-fail (or,
                    // worse, a spinner that can never resolve).
                    AinkradBanner(message: "Enter a Gmail OAuth client id and secret above to " +
                                  "enable Connect.", status: .warning)
                }
                AinkradButton(title: "Connect", style: .primary, icon: "person.badge.plus",
                              isLoading: isConnecting, action: connect)
                    .disabled(!runtime.isCredentialsBaked &&
                              (clientID.isEmpty || (clientSecret.isEmpty && !runtime.hasCredentials))
                              || isConnecting)
            }
        }
    }

    private func connect() {
        if !runtime.isCredentialsBaked && (!clientSecret.isEmpty || !runtime.hasCredentials) {
            guard !clientSecret.isEmpty else {
                connectError = "Enter the client secret to save new credentials."
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

    // MARK: Accounts

    private var accountsPanel: some View {
        AinkradSettingsPanel(title: "Accounts") {
            let accounts = { _ = accountsVersion; return runtime.accounts }()
            if accounts.isEmpty {
                AinkradEmptyState(icon: "envelope.badge", title: "No accounts connected",
                                  message: "Connect a Gmail account above.")
            } else {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                }
            }
        }
    }

    private func accountRow(_ account: MailAccount) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack {
                Text(account.address).font(.body.weight(.medium))
                statusBadge(account)
                Spacer()
                AinkradButton(title: "Sign Out", style: .danger, action: {
                    pendingSignOut = account
                })
            }
            if case .backfilling(let threadsSynced) = runtime.syncState(for: account.id) {
                // Live progress for the backfill `connectAccount`/
                // `resyncFromScratch` now run detached (see
                // `RavenRuntime.runBackfill`) — without this the Accounts
                // surface would just sit on the "Syncing" badge with nothing
                // else to look at for up to a minute.
                Text("Syncing… \(threadsSynced) thread\(threadsSynced == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let lastSyncedAt = account.lastSyncedAt {
                Text("Last synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let lastError = runtime.lastSyncError(for: account.id) ?? account.lastError {
                Text(lastError).font(.caption).foregroundStyle(.red)
            }
            if runtime.lastBackfillTruncated(for: account.id) {
                AinkradBanner(message: "The last backfill stopped early (page limit reached). " +
                              "Some older mail in the sync window may be missing.", status: .warning)
            }
            AinkradFormRow(title: "Signature") {
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
            HStack {
                AinkradButton(title: "Resync From Scratch", style: .secondary,
                              icon: "arrow.triangle.2.circlepath") {
                    // Kicks off and returns immediately — see
                    // `RavenRuntime.resyncFromScratch`'s documentation. Progress
                    // reaches this view via the `.onChange(of: runtime.syncState)`
                    // below, not a poll.
                    runtime.resyncFromScratch(accountID: account.id)
                }
                AinkradButton(title: "Sync Now", style: .ghost, icon: "arrow.clockwise") {
                    Task {
                        await runtime.syncNow(accountID: account.id)
                        accountsVersion += 1
                    }
                }
            }
        }
        .padding(AinkradSpacing.sm)
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

    // MARK: Outbox

    private var outboxPanel: some View {
        AinkradSettingsPanel(
            title: "Outbox",
            hint: "Operations queued for the server. \"Needs review\" entries were in flight " +
                  "when the app last quit — their outcome is unknown, so they are held here " +
                  "rather than silently resent; confirm whether the send happened before " +
                  "discarding."
        ) {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                outboxSection(title: "Needs review", entries: runtime.outboxNeedsReview)
                outboxSection(title: "Dead-lettered", entries: runtime.outboxDeadLettered)
            }
        }
        .onAppear { runtime.refreshOutboxSnapshots() }
    }

    @ViewBuilder
    private func outboxSection(title: String, entries: [OutboxEntry]) -> some View {
        AinkradSectionHeader(title: title, subtitle: entries.isEmpty ? "None" : nil)
        ForEach(entries) { entry in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(describe(entry.operation)).font(.body)
                    if let lastError = entry.lastError {
                        Text(lastError).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                AinkradButton(title: "Discard", style: .danger) {
                    runtime.discardOutboxEntry(entry.id)
                }
            }
            .padding(.vertical, AinkradSpacing.xs)
        }
    }

    private func describe(_ operation: OutboxEntry.Operation) -> String {
        switch operation {
        case .send(let message): return "Send: \(message.subject.isEmpty ? "(no subject)" : message.subject)"
        case .labels(let mutation): return "Labels on \(mutation.threadIDs.count) thread(s)"
        }
    }
}
