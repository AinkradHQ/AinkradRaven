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

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(RavenSettingsView(runtime: runtime(host: host)))
    }

    public static func makeMCPServer(host: HostServices) -> MCPAppServer {
        let runtime = runtime(host: host)
        return RavenMCPServer.make(appID: id) { operation, arguments in
            await RavenMCPOperations.run(operation, arguments: arguments,
                                        store: runtime.store, outbox: runtime.outbox)
        }.server
    }
}

/// Generation 8: release a closed instance's runtime — its live sync engine
/// and open outbox — rather than let it linger for the rest of the process.
/// The legacy `ObjectIdentifier` key for a generation-7 host is intentionally
/// left in `legacyIDs`: it is a tiny, bounded value (one `PluginInstanceID`
/// per legacy host ever seen), unlike the runtime itself, and generation-7
/// hosts never call `teardown` anyway.
extension RavenApp: AinkradAppTeardown {
    public static func teardown(instance: PluginInstanceID) {
        runtimes.remove(instance)
    }
}
