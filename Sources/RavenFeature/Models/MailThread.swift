import Foundation

public struct MailThread: Codable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public var messages: [MailMessage]   // oldest first

    public init(id: String, accountID: String, messages: [MailMessage]) {
        self.id = id; self.accountID = accountID; self.messages = messages
    }

    public var subject: String { messages.first?.subject ?? "" }
    public var lastMessageDate: Date { messages.last?.date ?? .distantPast }
    public var unreadCount: Int { messages.filter { !$0.isRead }.count }

    public func summary() -> ThreadSummary {
        var seen = Set<String>()
        var participants: [MailAddress] = []
        for address in messages.compactMap(\.from) where seen.insert(address.email).inserted {
            participants.append(address)
        }
        return ThreadSummary(
            id: id, accountID: accountID, subject: subject,
            participants: participants, lastMessageDate: lastMessageDate,
            messageCount: messages.count, unreadCount: unreadCount,
            isStarred: messages.contains(where: \.isStarred),
            labelIDs: Array(Set(messages.flatMap(\.labelIDs))).sorted(),
            snippet: messages.last?.snippet ?? "")
    }
}
