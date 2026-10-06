import AinkradAppKit
import Foundation
import RavenFeature

@objc(RavenPluginEntryPoint)
final class RavenPluginEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { RavenApp.self }
}
