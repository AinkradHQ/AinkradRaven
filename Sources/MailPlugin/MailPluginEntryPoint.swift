import Foundation
import AinkradAppKit
import MailFeature

@objc(MailPluginEntryPoint)
final class MailPluginEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { MailApp.self }
}
