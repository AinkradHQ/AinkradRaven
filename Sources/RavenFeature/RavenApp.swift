import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

public enum RavenApp: AinkradApp {
    /// Must match `AinkradAppID` in Info.plist — the host keys documents and
    /// Keychain secrets by this id, so changing it orphans existing data.
    public static var id: String { "raven" }
    public static var displayName: String { "Raven" }
    public static var icon: String { "bird" }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(AinkradPanel { Text("Raven") })
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(EmptyView())
    }
}
