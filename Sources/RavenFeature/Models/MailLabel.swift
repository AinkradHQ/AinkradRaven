import Foundation

public struct MailLabel: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case system, user }
    public let id: String
    public var name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id; self.name = name; self.kind = kind
    }
}
