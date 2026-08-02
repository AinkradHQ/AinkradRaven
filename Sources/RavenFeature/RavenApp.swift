import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

public enum RavenApp: AinkradApp, AinkradAppMCP {
    /// Must match `AinkradAppID` in Info.plist — the host keys documents and
    /// Keychain secrets by this id, so changing it orphans existing data.
    public static var id: String { "raven" }
    public static var displayName: String { "Raven" }
    public static var icon: String { "bird" }

    /// One `RavenRuntime` per host, so the on-screen UI and the MCP server
    /// share the same live store/outbox rather than two detached copies.
    /// Keyed by object identity because a host is handed to this app once per
    /// load and never compares equal to a different one.
    @MainActor private static var runtimes: [ObjectIdentifier: RavenRuntime] = [:]

    @MainActor static func runtime(host: HostServices) -> RavenRuntime {
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = runtimes[key] { return existing }
        let runtime = RavenRuntime(host: host)
        runtimes[key] = runtime
        return runtime
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
