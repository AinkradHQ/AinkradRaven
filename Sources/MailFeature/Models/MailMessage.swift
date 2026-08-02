import Foundation

public struct MailMessage: Codable, Equatable, Sendable {
    public let id: String              // provider message id
    public let threadID: String
    public let rfc822MessageID: String?
    public let from: MailAddress?
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let subject: String
    public let date: Date
    public var isRead: Bool
    public var isStarred: Bool
    public var labelIDs: [String]
    public let hasAttachments: Bool
    public let snippet: String

    public init(id: String, threadID: String, rfc822MessageID: String? = nil,
                from: MailAddress?, to: [MailAddress] = [], cc: [MailAddress] = [],
                subject: String, date: Date, isRead: Bool = false,
                isStarred: Bool = false, labelIDs: [String] = [],
                hasAttachments: Bool = false, snippet: String = "") {
        self.id = id; self.threadID = threadID; self.rfc822MessageID = rfc822MessageID
        self.from = from; self.to = to; self.cc = cc; self.subject = subject
        self.date = date; self.isRead = isRead; self.isStarred = isStarred
        self.labelIDs = labelIDs; self.hasAttachments = hasAttachments
        self.snippet = snippet
    }
}
