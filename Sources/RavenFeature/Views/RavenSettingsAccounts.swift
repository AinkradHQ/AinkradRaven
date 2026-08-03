import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The account list: every connected mailbox, its live state, its errors, and
/// the destructive actions that act on exactly one of them.
///
/// Extracted from `RavenSettingsView` so the SAME view backs both settings
/// surfaces — the `.custom` field in `RavenSettingsCatalog` (the real surface
/// now) and the thin `makeSettingsView` fallback. Two copies of an account list
/// is how one of them quietly loses the read-only badge or the truncated-
/// backfill banner.
///
/// This is the field that genuinely cannot be declarative, and it is worth
/// saying why rather than asserting it: a `SettingsField` is one label and one
/// control. This is a variable-length list whose every row carries a live
/// status badge, a live backfill counter, up to two error banners, a
/// disclosure, and a destructive action that has to name the specific address
/// it will erase. There is no `SettingsFieldKind` that is "a list of accounts",
/// and flattening it into per-account toggles would lose exactly the state and
/// error reporting that makes it useful.
struct RavenAccountsPane: View {
    let runtime: RavenRuntime
    /// Whether each account's signature editor renders here.
    ///
    /// False on the catalog surface, where the signature is a real declarative
    /// `.text` field (`RavenSettingsCatalog.signatureFields`) and rendering it
    /// twice would give one value two controls on one page. True on the
    /// `makeSettingsView` fallback, which has no declarative fields at all and
    /// would otherwise drop the setting entirely.
    let showsSignature: Bool

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

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
    /// Which account rows have their details (signature, sync history, resync)
    /// open. Collapsed by default so several connected accounts read as a list
    /// of accounts rather than three screens of forms.
    @State private var expandedAccounts: Set<String> = []

    init(runtime: RavenRuntime, showsSignature: Bool) {
        self.runtime = runtime
        self.showsSignature = showsSignature
    }

    var body: some View {
        accountsBody
            .ainkradConfirmDialog(
                isPresented: Binding(
                    get: { pendingSignOut != nil },
                    set: { if !$0 { pendingSignOut = nil } }),
                title: "Sign out",
                // Names the address it will erase — never a bare "Sign out?".
                message: "Sign out of \(pendingSignOut?.address ?? "this account")? Every local " +
                         "copy of its mail and any queued sends for it will be removed from " +
                         "this device. Other connected accounts are not affected.",
                confirmTitle: "Sign Out",
                isDestructive: true,
                onConfirm: {
                    guard let account = pendingSignOut else { return }
                    runtime.signOut(account.id)
                    accountsVersion += 1
                })
            .onAppear {
                for account in runtime.accounts { signatures[account.id] = account.signature }
            }
            // `runtime.accounts` is a plain snapshot method, not `@Observable`
            // storage, so nothing re-reads it just because `runtime.syncState`
            // changed underneath. This is the push replacement for the old
            // polling: `SyncEngine.onChange` (via
            // `RavenRuntime.mirrorSyncEngineState`) updates `syncState` on
            // every backfill page and on every delta sync, and THIS is what
            // turns each of those pushes into a fresh read of
            // `runtime.accounts` — including the final one, where `state`/
            // `lastSyncedAt`/`lastError` land after a backfill or delta
            // finishes.
            .onChange(of: runtime.syncState) { _, _ in accountsVersion += 1 }
    }

    @ViewBuilder
    private var accountsBody: some View {
        let accounts = { _ = accountsVersion; return runtime.accounts }()
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            if accounts.isEmpty {
                AinkradEmptyState(
                    icon: "envelope.badge",
                    title: "No accounts connected",
                    message: "Connect a Gmail account to start syncing mail into Raven.",
                    actionTitle: "Connect Gmail",
                    action: { connect() })
                    .frame(height: 220)
                    .disabled(!runtime.canConnectAccount || isConnecting)
            } else {
                ForEach(accounts) { account in
                    accountRow(account)
                }
                AinkradButton(title: "Connect Another Account", style: .secondary,
                              icon: "person.badge.plus", isLoading: isConnecting,
                              action: { connect() })
                    .disabled(!runtime.canConnectAccount || isConnecting)
            }
            if let connectError {
                AinkradBanner(message: connectError, status: .danger,
                              onDismiss: { self.connectError = nil })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if showsSignature, !runtime.isReadOnly(accountID: account.id) {
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

    /// Starts the OAuth flow. Unchanged from the version that lived in
    /// `RavenSettingsView`, including the "save typed credentials first" step —
    /// except that the credentials themselves are now declarative fields
    /// (`RavenSettingsCatalog`), so this no longer owns their text and reads
    /// what was saved instead.
    private func connect() {
        guard runtime.canConnectAccount else {
            connectError = "Enter a Gmail OAuth client id and secret before connecting."
            return
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
