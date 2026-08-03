import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

public enum RavenApp: AinkradApp, AinkradAppMCP {
    /// Must match `AinkradAppID` in Info.plist — the host keys documents and
    /// Keychain secrets by this id, so changing it orphans existing data.
    public static var id: String { "raven" }
    public static var displayName: String { "Raven" }
    public static var icon: String { "bird" }

    /// One `RavenRuntime` per host instance. Keyed by the host-minted
    /// `PluginInstanceID` rather than `ObjectIdentifier(host)` — see
    /// `PluginLifecycle.swift`'s own documentation of why that key is a real
    /// bug: `HostServices` is not class-bound, `host as AnyObject` may box a
    /// value, and a box's address is reused after it is freed, so a NEW host
    /// could be handed the PREVIOUS host's store/outbox. `Quest` (`QuestApp.swift`)
    /// already adopted `PluginInstanceStorage` for exactly this reason; this
    /// mirrors that.
    @MainActor private static let runtimes = PluginInstanceStorage<RavenRuntime>()

    /// The instance key for `host`. A generation-8 host mints a real
    /// `PluginInstanceID` via `PluginInstanceIdentity`. A generation-7 host
    /// does not implement that protocol, so this falls back to the OLD
    /// per-host object identity — kept ONLY on this legacy path, exactly as
    /// `QuestApp.instance(of:)` does, so two legacy hosts still never
    /// collapse onto one shared key.
    @MainActor private static func instance(of host: HostServices) -> PluginInstanceID {
        if let identified = host as? PluginInstanceIdentity { return identified.instanceID }
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = legacyIDs[key] { return existing }
        let minted = PluginInstanceID()
        legacyIDs[key] = minted
        return minted
    }
    @MainActor private static var legacyIDs: [ObjectIdentifier: PluginInstanceID] = [:]

    @MainActor static func runtime(host: HostServices) -> RavenRuntime {
        runtimes.value(for: instance(of: host)) { RavenRuntime(host: host) }
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(RavenShell(runtime: runtime(host: host)))
    }

    /// The fallback the protocol describes, for a host that does not consume
    /// `settingsCatalog`. Deliberately thin now: `RavenSettingsView` stacks the
    /// same group views the catalog publishes, in the same order, so this
    /// surface cannot silently lose a setting the catalog has — but the catalog
    /// is the real surface, and this is what a generation-7 host gets.
    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(RavenSettingsView(runtime: runtime(host: host)))
    }

    /// Raven's settings published as descriptors so the host can index them,
    /// deep-link into them, and lay them out with every other setting using its
    /// own `SettingsPageView`/`SettingsGroupView`/`SettingsRow`. See
    /// `RavenSettingsCatalog` for the group breakdown, why the paths are
    /// relative, and why the tab bar the five groups produce is the host's
    /// rather than ours.
    ///
    /// `host.theme` is passed through because the host does NOT apply its theme
    /// bridge to this closure the way it does to `makeRootView`/
    /// `makeSettingsView` — see `RavenSettingsCatalog.pane`.
    public static func settingsCatalog(host: HostServices) -> SettingsPage? {
        let runtime = runtime(host: host)
        return RavenSettingsCatalog.page(runtime: runtime, draft: runtime.settingsDraft,
                                        theme: host.theme)
    }

    public static func makeMCPServer(host: HostServices) -> MCPAppServer {
        let runtime = runtime(host: host)
        return RavenMCPServer.make(appID: id) { operation, arguments in
            await RavenMCPOperations.run(operation, arguments: arguments,
                                        store: runtime.store, outbox: runtime.outbox,
                                        providers: runtime.providers)
        }.server
    }
}

/// Generation 8: release a closed instance's runtime — its live sync engine
/// and open outbox — rather than let it linger for the rest of the process.
/// The legacy `ObjectIdentifier` key for a generation-7 host is intentionally
/// left in `legacyIDs`: it is a tiny, bounded value (one `PluginInstanceID`
/// per legacy host ever seen), unlike the runtime itself, and generation-7
/// hosts never call `teardown` anyway.
///
/// `runtime.teardown()` runs BEFORE the entry is dropped from `runtimes` —
/// it cancels the sync poll loop and unregisters the agent context/actions
/// this instance published (`RavenAgentBridge.register`). Skipping that and
/// only evicting the dictionary entry would leave a closed instance's timer
/// polling Gmail forever and its stale closures still reachable from the
/// host's registries — the same leak class this teardown exists to close.
extension RavenApp: AinkradAppTeardown {
    public static func teardown(instance: PluginInstanceID) {
        runtimes.remove(instance)?.teardown()
    }
}
