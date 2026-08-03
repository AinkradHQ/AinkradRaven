import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Transient text the settings form holds but does not persist until asked.
///
/// Only the OAuth client id/secret need this. A `.secure` field's binding is
/// written on every keystroke, and `RavenRuntime.saveCredentials` needs BOTH
/// values at once (it constructs a `GmailAuth` from the pair), so a
/// keystroke-by-keystroke write-through would build an auth object out of a
/// half-typed secret and store a broken credential in the Keychain. Saving is
/// therefore its own `.action` field, and this holds the pair until it fires.
///
/// It has to be observable and it has to outlive a render pass: the host
/// rebuilds the whole catalog on every settings-overlay body evaluation
/// (`SettingsOverlayView.catalog` is a computed property), so anything stored
/// in the catalog itself is discarded between keystrokes. `RavenRuntime` is the
/// only object here with the right lifetime.
@MainActor @Observable public final class RavenSettingsDraft {
    public var clientID = ""
    public var clientSecret = ""
    public init() {}

    /// Both halves present, so `saveCredentials` would produce a usable pair.
    public var canSaveCredentials: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.isEmpty
    }
}

/// Raven's settings published as descriptors, per `AinkradApp.settingsCatalog`.
///
/// This is the real settings surface now. The host renders what it returns with
/// `SettingsPageView` + `SettingsGroupView` + `SettingsRow` — the same
/// components the General page is built from, which is what makes Raven's
/// settings finally look like the rest of the app instead of a hand-composed
/// column of panels — and indexes every field for search and deep-linking.
///
/// **The tabs are a consequence, not a construction.** `SettingsPageView.
/// usesTabs(page:)` turns a page into a top tab bar, one tab per group, at
/// three or more groups. Returning five groups is therefore all the tab bar
/// requires; there is deliberately no tab-bar code in this plugin, and there
/// must not be, because a bespoke one would not match the host's.
///
/// Two facts about how the host consumes this, both load-bearing here and
/// neither obvious from the protocol:
///
/// 1. **Paths are re-rooted.** `AppSettingsCatalog` prefixes every group and
///    field path with `["app", "raven"]` before it enters the catalog, as an
///    untrusted-input measure. So the paths declared here are RELATIVE. The
///    plugin template declares an absolute `["app", id]` root and consequently
///    double-prefixes itself; this does not.
/// 2. **The host appends its own "Appearance" group** (its per-app blur
///    toggle) to every plugin page. That is why the transparency group here is
///    called "Transparency" and not "Appearance": two groups with the same
///    title become two identically-labelled tabs, and the host's group is not
///    ours to rename. The two settings are genuinely different — the host's
///    blurs the workspace revealed BEHIND Raven's window, ours controls how
///    see-through Raven's own panes are.
@MainActor
enum RavenSettingsCatalog {
    /// The declared groups, in tab order. Five of them, so the host's tab bar
    /// engages with room to spare even before it appends its own sixth.
    static func page(runtime: RavenRuntime, draft: RavenSettingsDraft,
                     theme: HostTheme) -> SettingsPage {
        SettingsPage(
            // `path`, `title`, `icon`, `group`, `order` and `appID` are all
            // overridden by `AppSettingsCatalog` (it uses the registered app's
            // metadata and forces plugins into `.installedApps`). They are
            // supplied honestly anyway rather than left as placeholders, so
            // this reads correctly if the host ever stops overriding them.
            path: SettingsPath(["raven"]),
            title: "Raven",
            icon: "bird",
            group: .installedApps,
            order: 0,
            groups: [
                accounts(runtime: runtime, draft: draft, theme: theme),
                sending(runtime: runtime),
                rules(runtime: runtime, theme: theme),
                privacy(runtime: runtime, theme: theme),
                transparency(runtime: runtime)
            ],
            appID: "raven",
            // The host DOES honour this one. It puts the needs-review +
            // dead-letter count on Raven's sidebar row, so the queue that can
            // mean a message did not go out is visible without opening the
            // page at all — strictly better than the old arrangement, where it
            // was a panel you had to already be looking at. A closure, not a
            // count: the number changes while the overlay is open.
            badge: { runtime.outboxNeedsReview.count + runtime.outboxDeadLettered.count })
    }

    // MARK: Accounts

    private static func accounts(runtime: RavenRuntime, draft: RavenSettingsDraft,
                                 theme: HostTheme) -> SettingsGroup {
        let root = SettingsPath(["accounts"])
        var fields: [SettingsField] = [
            // First field in the first group: the outbox entries a human has to
            // resolve. Position is the point — these are the only things in
            // settings that can mean a message did not go out, and they used to
            // be the last panel on the page. `OutboxAttentionGroup` renders
            // NOTHING when both queues are empty (see its own documentation for
            // why an always-present "Outbox — None" heading is worse than
            // nothing), so this costs no space in the normal case.
            //
            // Always declared, never conditionally omitted: gating it on a
            // currently-empty snapshot would mean the view that REFRESHES that
            // snapshot (`refreshOutboxSnapshots`, in its `onAppear`) never
            // renders, and a queue that filled up since the last refresh would
            // stay invisible.
            SettingsField(
                path: root.appending("attention"),
                label: "Needs your attention",
                help: "Queued sends whose outcome is unknown, and sends that were retried "
                    + "until they gave up.",
                keywords: ["outbox", "dead", "letter", "review", "failed", "stuck", "unsent"],
                kind: .custom(pane(OutboxAttentionGroup(runtime: runtime), theme: theme))),
            SettingsField(
                path: root.appending("list"),
                label: "Connected accounts",
                help: "Each mailbox, its sync state, its errors, and sign-out.",
                keywords: ["account", "gmail", "mailbox", "connect", "sign out", "sync",
                           "resync", "read-only", "apple mail"],
                kind: .custom(pane(
                    RavenAccountsPane(runtime: runtime, showsSignature: false), theme: theme)))
        ]

        fields += signatureFields(runtime: runtime, root: root)

        // Manual client id/secret entry is a fallback for a developer build
        // with no `Config/oauth-client.json`. With credentials baked in there
        // is nothing to type, and offering the fields anyway invites a user to
        // overwrite a working client with their own — so they are not declared
        // at all rather than declared-and-disabled, which also keeps them out
        // of the search index where they would be a dead end.
        if !runtime.isCredentialsBaked {
            fields += credentialFields(runtime: runtime, draft: draft, root: root)
        }

        return SettingsGroup(
            path: root,
            title: "Accounts",
            footerNote: runtime.isCredentialsBaked
                ? "Signing out of an account erases every local copy of its mail and any queued "
                  + "sends for it from this device. Other connected accounts are untouched."
                : "This build has no OAuth client compiled in, so a Google Cloud Desktop client "
                  + "id and secret are needed before an account can be connected. The secret is "
                  + "stored in the system Keychain, never as a plain document.",
            fields: fields)
    }

    /// One `.text` field per account that can actually send.
    ///
    /// Declarative on purpose: a signature is a string with a label, which is
    /// precisely what `.text` is for, and making it a real field is what gets
    /// it into the host's search index — "signature" now finds this, which it
    /// could not when the control was buried inside a `.custom` pane's
    /// disclosure. Read-only accounts (Apple Mail imports) are skipped: they
    /// have no transport, so a signature for one is a field that can never take
    /// effect.
    private static func signatureFields(runtime: RavenRuntime,
                                        root: SettingsPath) -> [SettingsField] {
        runtime.accounts
            .filter { !runtime.isReadOnly(accountID: $0.id) }
            .map { account in
                let id = account.id
                return SettingsField(
                    path: root.appending("signature").appending(id),
                    label: "Signature — \(account.address)",
                    help: "Appended to every message sent from this account.",
                    keywords: ["signature", "sign-off", account.address],
                    kind: .text(Binding(
                        // Read through the store each time rather than
                        // capturing `account`, which is a snapshot taken when
                        // the catalog was built. Writing a stale snapshot back
                        // is the bug that used to clobber syncCursor /
                        // lastSyncedAt / state / lastError and silently
                        // re-backfill the mailbox; `updateSignature` does a
                        // read-modify-write of the CURRENT row instead.
                        get: { runtime.accounts.first { $0.id == id }?.signature ?? "" },
                        set: { runtime.updateSignature($0, accountID: id) })),
                    defaultDescription: "Empty",
                    isModified: {
                        !(runtime.accounts.first { $0.id == id }?.signature ?? "").isEmpty
                    },
                    reset: { runtime.updateSignature("", accountID: id) })
            }
    }

    /// Client id, secret, and an explicit save. Three real fields rather than a
    /// `.custom` pane — see `RavenSettingsDraft` for why saving is a separate
    /// action instead of a write-through on the secure field.
    private static func credentialFields(runtime: RavenRuntime, draft: RavenSettingsDraft,
                                         root: SettingsPath) -> [SettingsField] {
        let clientRoot = root.appending("oauth")
        return [
            SettingsField(
                path: clientRoot.appending("client-id"),
                label: "OAuth client ID",
                help: "The Desktop client id from Google Cloud Console.",
                keywords: ["oauth", "client", "google", "credentials"],
                kind: .text(Binding(
                    get: { draft.clientID.isEmpty ? (runtime.savedClientID ?? "") : draft.clientID },
                    set: { draft.clientID = $0 })),
                isAdvanced: true),
            SettingsField(
                path: clientRoot.appending("client-secret"),
                label: "OAuth client secret",
                // Never read back — there is deliberately no getter for the
                // stored secret (see `RavenRuntime.clientSecretKey`), so this
                // shows what is being typed and nothing else.
                help: "Stored in the system Keychain. Never shown again once saved.",
                keywords: ["oauth", "secret", "google", "credentials", "keychain"],
                kind: .secure(Binding(get: { draft.clientSecret },
                                      set: { draft.clientSecret = $0 })),
                isAdvanced: true),
            SettingsField(
                path: clientRoot.appending("save"),
                label: "Save client credentials",
                help: draft.canSaveCredentials
                    ? "Saves the pair above and enables Connect."
                    : "Enter both the client id and the secret first.",
                keywords: ["oauth", "save", "credentials"],
                kind: .action(title: "Save") {
                    guard draft.canSaveCredentials else { return }
                    runtime.saveCredentials(clientID: draft.clientID,
                                            clientSecret: draft.clientSecret)
                    // The secret is not kept in memory past the save. The id is,
                    // because it is not a credential and the field should keep
                    // showing it.
                    draft.clientSecret = ""
                },
                isAdvanced: true)
        ]
    }

    // MARK: Sending

    private static func sending(runtime: RavenRuntime) -> SettingsGroup {
        let root = SettingsPath(["sending"])
        return SettingsGroup(
            path: root,
            title: "Sending",
            // The prose that used to be crammed into a panel hint and a
            // trailing caption. This is what `footerNote` is for.
            footerNote: "The undo window applies both to messages you send yourself and to ones "
                + "Sage sends with send_draft, so this one setting covers both. Zero means a "
                + "message goes the moment you press Send, with no undo.\n\n"
                + "Scheduled sends fire only while Raven is running. A message scheduled for "
                + "3am while your Mac is asleep sends when the app next wakes, not at 3am.",
            fields: [
                SettingsField(
                    path: root.appending("undo-window"),
                    label: "Undo window",
                    help: "Seconds a sent message stays cancelable. The composer shows a live "
                        + "countdown for this long.",
                    keywords: ["undo", "send", "hold", "delay", "cancel", "recall"],
                    // A slider, not the old text field plus five preset chips.
                    // The value is a bounded number with no meaningful precision
                    // beyond five seconds, which is the definition of a slider —
                    // and the text field allowed a half-typed number to briefly
                    // read as a valid setting, which the whole `holdWindowText`
                    // mirror existed to work around.
                    kind: .slider(range: 0...60, step: 5, value: Binding(
                        get: { runtime.holdWindow },
                        set: { runtime.holdWindow = $0 })),
                    defaultDescription: "\(Int(SendAttempt.defaultHoldWindow)) seconds",
                    isModified: { runtime.holdWindow != SendAttempt.defaultHoldWindow },
                    reset: { runtime.holdWindow = SendAttempt.defaultHoldWindow })
            ])
    }

    // MARK: Rules

    private static func rules(runtime: RavenRuntime, theme: HostTheme) -> SettingsGroup {
        SettingsGroup(
            path: SettingsPath(["rules"]),
            title: "Rules",
            fields: [
                SettingsField(
                    path: SettingsPath(["rules", "editor"]),
                    label: "Filter rules",
                    help: "Match incoming mail and act on it automatically.",
                    keywords: ["rule", "filter", "automation", "label", "archive", "match"],
                    // Genuinely not declarative: a rule is a list of
                    // conditions and a list of actions, the set of rules is
                    // reorderable and variable-length, and each row is itself a
                    // small form. There is no `SettingsFieldKind` for "an
                    // editor", which is exactly the case `.custom` documents
                    // itself as existing for.
                    kind: .custom(pane(RulesSettingsGroup(runtime: runtime), theme: theme)))
            ])
    }

    // MARK: Privacy

    private static func privacy(runtime: RavenRuntime, theme: HostTheme) -> SettingsGroup {
        SettingsGroup(
            path: SettingsPath(["privacy"]),
            title: "Privacy",
            fields: [
                SettingsField(
                    path: SettingsPath(["privacy", "remote-images"]),
                    label: "Senders allowed to load images",
                    help: "Remote images are blocked everywhere by default; this is who is "
                        + "exempt, and how to revoke that.",
                    keywords: ["privacy", "images", "remote", "tracking", "pixel", "allow",
                               "block", "revoke", "csp"],
                    // A variable-length list of addresses, each with its own
                    // destructive Revoke — not a toggle, and not a value with a
                    // default worth resetting.
                    kind: .custom(pane(PrivacySettingsGroup(runtime: runtime), theme: theme)))
            ])
    }

    // MARK: Transparency

    private static func transparency(runtime: RavenRuntime) -> SettingsGroup {
        let root = SettingsPath(["transparency"])
        let store = runtime.appearanceStore
        return SettingsGroup(
            path: root,
            title: "Transparency",
            footerNote: "How much of the workspace shows through Raven's inbox rail, reading "
                + "pane, message cards and composer. The slider stops short of fully clear on "
                + "purpose: past that point whatever is behind the window dominates and no text "
                + "colour stays readable, so body text would become unreadable at a setting you "
                + "then could not see well enough to undo. Blur is how the workspace behind the "
                + "panes is sampled — Deep is heavier and more diffuse than Panel.",
            fields: [
                SettingsField(
                    path: root.appending("opacity"),
                    label: "Surface opacity",
                    help: "Lower is more see-through.",
                    keywords: ["transparency", "translucent", "opacity", "glass", "blur",
                               "see-through", "appearance"],
                    kind: .slider(
                        range: RavenAppearance.legibleRange, step: 0.05,
                        value: Binding(
                            get: { store.appearance.surfaceOpacity },
                            set: { store.appearance.rawSurfaceOpacity = $0 })),
                    defaultDescription: "\(Int(RavenAppearance.defaultSurfaceOpacity * 100))%",
                    isModified: {
                        store.appearance.surfaceOpacity != RavenAppearance.default.surfaceOpacity
                    },
                    reset: {
                        store.appearance.rawSurfaceOpacity = RavenAppearance.defaultSurfaceOpacity
                    }),
                SettingsField(
                    path: root.appending("blur"),
                    label: "Blur",
                    help: "The material behind Raven's panes.",
                    keywords: ["blur", "material", "vibrancy", "appearance"],
                    kind: .select(
                        options: RavenAppearance.Blur.allCases.map {
                            SettingsOption(id: $0.rawValue, title: $0.title)
                        },
                        selection: Binding(
                            get: { store.appearance.blur.rawValue },
                            set: {
                                guard let blur = RavenAppearance.Blur(rawValue: $0) else { return }
                                store.appearance.blur = blur
                            })),
                    defaultDescription: RavenAppearance.default.blur.title,
                    isModified: { store.appearance.blur != RavenAppearance.default.blur },
                    reset: { store.appearance.blur = RavenAppearance.default.blur })
            ])
    }

    // MARK: Custom-pane plumbing

    /// Wraps a `.custom` pane's view for the host's settings overlay.
    ///
    /// The theme bridge is applied HERE and not by the host, which is the
    /// reason this helper exists. `PluginLoader` wraps `makeRootView` and
    /// `makeSettingsView` in `.ainkradHostTheme(host.theme)` but does NOT wrap
    /// the `settingsCatalog` closure, so an `AnyView` handed over inside
    /// `.custom` arrives with whatever theme the overlay happens to have in the
    /// environment rather than the one this plugin was given. In practice those
    /// are usually the same theme, which is exactly what would make the
    /// omission ship unnoticed and then break the day they diverge.
    private static func pane(_ view: some View, theme: HostTheme) -> AnyView {
        AnyView(view.ainkradHostTheme(theme))
    }
}
