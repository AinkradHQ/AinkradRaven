import Foundation

public struct MailAddress: Codable, Equatable, Hashable, Sendable {
    public let email: String
    public let name: String?

    public init(email: String, name: String? = nil) {
        self.email = email
        self.name = name
    }

    /// Parses `Name <a@b.c>` and bare `a@b.c`. Returns nil when there is no `@`.
    public init?(rfc5322 raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"),
           open < close {
            let address = String(trimmed[trimmed.index(after: open)..<close])
            guard address.contains("@") else { return nil }
            let label = String(trimmed[trimmed.startIndex..<open])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            self.init(email: address, name: label.isEmpty ? nil : label)
            return
        }
        guard trimmed.contains("@") else { return nil }
        self.init(email: trimmed, name: nil)
    }

    public var displayLabel: String { name ?? email }
}
