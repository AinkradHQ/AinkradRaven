import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

public enum MailApp: AinkradApp {
    public static var id: String { "mail" }
    public static var displayName: String { "Mail" }
    public static var icon: String { "envelope" }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(AinkradPanel { Text("Mail") })
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(EmptyView())
    }
}
