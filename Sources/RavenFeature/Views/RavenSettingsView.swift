import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The `makeSettingsView` fallback — what a host that does not consume
/// `AinkradApp.settingsCatalog` gets.
///
/// It used to be the only settings surface and was 340 lines of hand-composed
/// panels: an accounts list, an OAuth credentials form, a sending form, a rules
/// editor, a privacy list and an outbox section, each drawing its own chrome and
/// none of them looking like the host's own General page. That is what
/// `RavenSettingsCatalog` replaces, by publishing descriptors the host lays out
/// with `SettingsPageView`/`SettingsGroupView`/`SettingsRow` — the exact
/// components General uses — and gets a tab bar from for free.
///
/// So this is now a stack of the SAME group views the catalog publishes, in the
/// same order, plus the two controls the catalog expresses declaratively
/// (signature, OAuth credentials) which are handed back to `RavenAccountsPane`'s
/// own `showsSignature` path so this surface does not lose them.
///
/// Nothing here is a second implementation of anything. If a group gains a
/// setting, it gains it in the group view, and both surfaces get it.
public struct RavenSettingsView: View {
    let runtime: RavenRuntime

    /// Collapsed by default: with credentials baked into the app (the shipped
    /// case) there is nothing in here at all, and even without them it is a
    /// once-per-machine step that should not be the first thing on the page.
    @State private var credentialsExpanded = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var saveError: String?

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    public init(runtime: RavenRuntime) { self.runtime = runtime }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.lg) {
                // Same order as the catalog's groups, with the attention queue
                // first for the same reason: it is the only thing in settings
                // that can mean a message did not go out.
                OutboxAttentionGroup(runtime: runtime)
                AinkradSettingsPanel(
                    title: "Accounts",
                    hint: "Each connected mailbox, its sync state, and the signature appended "
                        + "to messages sent from it."
                ) {
                    RavenAccountsPane(runtime: runtime, showsSignature: true)
                }
                credentialsPanel
                SendingSettingsGroup(runtime: runtime)
                RulesSettingsGroup(runtime: runtime)
                PrivacySettingsGroup(runtime: runtime)
                TransparencySettingsGroup(runtime: runtime)
            }
            .padding(AinkradSpacing.lg)
        }
        .ravenSurface(runtime.appearanceStore.appearance)
        .onAppear { clientID = runtime.savedClientID ?? clientID }
    }

    // MARK: Credentials

    /// The manual OAuth client form. Present only on this surface; on the
    /// catalog surface these are real `.text`/`.secure`/`.action` fields.
    @ViewBuilder
    private var credentialsPanel: some View {
        AinkradSettingsPanel(
            title: "Google OAuth client",
            hint: runtime.isCredentialsBaked
                ? "OAuth credentials are built into this app — nothing to configure."
                : "The Desktop OAuth client id and secret from Google Cloud Console. "
                  + "The secret is stored in the system Keychain, never as a plain document."
        ) {
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
                        caption("This build ships with its own Google OAuth client, so there is "
                                + "nothing to enter here.")
                    } else {
                        AinkradFormRow(title: "Client ID", controlWidth: 340) {
                            AinkradTextField(text: $clientID,
                                            placeholder: "xxxx.apps.googleusercontent.com")
                        }
                        AinkradFormRow(title: "Client secret", controlWidth: 340) {
                            AinkradSecureField(text: $clientSecret, placeholder: "Client secret")
                        }
                        // An explicit save, matching the catalog's `.action`
                        // field: `saveCredentials` builds a `GmailAuth` from the
                        // PAIR, so writing through on each keystroke would store
                        // a credential made from a half-typed secret.
                        AinkradButton(title: "Save Client Credentials", style: .secondary) {
                            save()
                        }
                        if let saveError {
                            AinkradBanner(message: saveError, status: .warning,
                                          onDismiss: { self.saveError = nil })
                        }
                    }
                }
            }
        }
    }

    private func save() {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty, !clientSecret.isEmpty else {
            saveError = "Enter both the client id and the secret."
            return
        }
        runtime.saveCredentials(clientID: clientID, clientSecret: clientSecret)
        // Not held in memory past the save. The id stays — it is not a
        // credential and the field should keep showing it.
        clientSecret = ""
        saveError = nil
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AinkradFontResolver.font(.caption, typography: typo))
            .foregroundStyle(theme.foreground.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The transparency controls on the fallback surface. The catalog expresses
/// these as a `.slider` and a `.select`; this is the hand-built equivalent, and
/// it exists so the fallback does not ship a Raven whose translucency cannot be
/// changed at all.
struct TransparencySettingsGroup: View {
    let runtime: RavenRuntime

    var body: some View {
        let store = runtime.appearanceStore
        AinkradSettingsPanel(
            title: "Transparency",
            hint: "How much of the workspace shows through Raven's panes. The slider stops "
                + "short of fully clear on purpose — past that point no text colour stays "
                + "readable. Blur is how the workspace behind the panes is sampled."
        ) {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                AinkradFormRow(title: "Surface opacity",
                              help: "Lower is more see-through.", controlWidth: 260) {
                    AinkradSlider(
                        value: Binding(get: { store.appearance.surfaceOpacity },
                                       set: { store.appearance.rawSurfaceOpacity = $0 }),
                        in: RavenAppearance.legibleRange)
                }
                AinkradFormRow(title: "Blur", help: "The material behind Raven's panes.",
                              controlWidth: 260) {
                    AinkradSegmentedPicker(
                        items: RavenAppearance.Blur.allCases,
                        selection: Binding(get: { store.appearance.blur },
                                           set: { store.appearance.blur = $0 }),
                        label: { $0.title })
                }
            }
        }
    }
}
