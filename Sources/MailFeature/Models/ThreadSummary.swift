import Foundation

/// One row in a month index shard. Deliberately small: the inbox list decodes
/// thousands of these and must never pull in a body.
public struct ThreadSummary: Codable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public var subject: String
    public var participants: [MailAddress]
    public var lastMessageDate: Date
    public var messageCount: Int
    public var unreadCount: Int
    public var isStarred: Bool
    public var labelIDs: [String]
    public var snippet: String

    public init(id: String, accountID: String, subject: String,
                participants: [MailAddress], lastMessageDate: Date,
                messageCount: Int, unreadCount: Int, isStarred: Bool,
                labelIDs: [String], snippet: String) {
        self.id = id; self.accountID = accountID; self.subject = subject
        self.participants = participants; self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount; self.unreadCount = unreadCount
        self.isStarred = isStarred; self.labelIDs = labelIDs; self.snippet = snippet
    }
}
