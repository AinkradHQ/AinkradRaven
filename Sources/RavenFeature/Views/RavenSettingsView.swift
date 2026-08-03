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
    @State private var signature = ""
    /// Bumped after any mutation so this view re-reads `runtime.accounts`,
    /// which is a plain (non-`@Observable`) snapshot method.
    @State private var accountsVersion = 0

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
        .onAppear {
            clientID = runtime.savedClientID ?? clientID
            signature = runtime.accounts.first?.signature ?? ""
        }
    }

    // MARK: Credentials

    private var credentialsPanel: some View {
        AinkradSettingsPanel(
            title: "Gmail account",
            hint: "The Desktop OAuth client id and secret from Google Cloud Console. " +
                  "The secret is stored in the system Keychain, never as a plain document."
        ) {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                AinkradFormRow(title: "Client ID") {
                    AinkradTextField(text: $clientID, placeholder: "xxxx.apps.googleusercontent.com")
                        .frame(width: 340)
                }
                AinkradFormRow(title: "Client secret") {
                    AinkradSecureField(text: $clientSecret, placeholder: "Client secret")
                        .frame(width: 340)
                }
                if let connectError {
                    AinkradBanner(message: connectError, status: .danger,
                                  onDismiss: { self.connectError = nil })
                }
                AinkradButton(title: "Connect", style: .primary, icon: "person.badge.plus",
                              isLoading: isConnecting, action: connect)
                    .disabled(clientID.isEmpty || (clientSecret.isEmpty && !runtime.hasCredentials)
                              || isConnecting)
            }
        }
    }

    private func connect() {
        if !clientSecret.isEmpty || !runtime.hasCredentials {
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
                signature = runtime.accounts.first?.signature ?? signature
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
                    runtime.signOut(account.id)
                    accountsVersion += 1
                })
            }
            if let lastSyncedAt = account.lastSyncedAt {
                Text("Last synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let lastError = account.lastError {
                Text(lastError).font(.caption).foregroundStyle(.red)
            }
            if runtime.lastBackfillTruncated {
                AinkradBanner(message: "The last backfill stopped early (page limit reached). " +
                              "Some older mail in the sync window may be missing.", status: .warning)
            }
            AinkradFormRow(title: "Signature") {
                AinkradTextArea(text: $signature, placeholder: "Signature", minHeight: 60)
                    // Read-modify-write the CURRENT row rather than writing
                    // back `account`, which is a snapshot captured when this
                    // row was rendered: writing that back on every keystroke
                    // clobbered syncCursor/lastSyncedAt/state/lastError with
                    // stale values, silently re-walking (or fully
                    // re-backfilling) the mailbox.
                    .onChange(of: signature) { _, newValue in
                        runtime.updateSignature(newValue, accountID: account.id)
                    }
            }
            HStack {
                AinkradButton(title: "Resync From Scratch", style: .secondary,
                              icon: "arrow.triangle.2.circlepath") {
                    Task {
                        await runtime.resyncFromScratch()
                        accountsVersion += 1
                    }
                }
                AinkradButton(title: "Sync Now", style: .ghost, icon: "arrow.clockwise") {
                    Task {
                        await runtime.syncNow()
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
