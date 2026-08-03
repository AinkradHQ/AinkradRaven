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
    /// Attachment metadata carried alongside the message. `hasAttachments`
    /// remains true whenever this is non-empty, but the two are decoded
    /// independently: `hasAttachments` predates this field and older stored
    /// documents decode `attachments` as `[]` via `decodeIfPresent` below
    /// rather than failing to decode at all.
    public let attachments: [MailAttachment]

    public init(id: String, threadID: String, rfc822MessageID: String? = nil,
                from: MailAddress?, to: [MailAddress] = [], cc: [MailAddress] = [],
                subject: String, date: Date, isRead: Bool = false,
                isStarred: Bool = false, labelIDs: [String] = [],
                hasAttachments: Bool = false, snippet: String = "",
                attachments: [MailAttachment] = []) {
        self.id = id; self.threadID = threadID; self.rfc822MessageID = rfc822MessageID
        self.from = from; self.to = to; self.cc = cc; self.subject = subject
        self.date = date; self.isRead = isRead; self.isStarred = isStarred
        self.labelIDs = labelIDs; self.hasAttachments = hasAttachments
        self.snippet = snippet; self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadID = try container.decode(String.self, forKey: .threadID)
        rfc822MessageID = try container.decodeIfPresent(String.self, forKey: .rfc822MessageID)
        from = try container.decodeIfPresent(MailAddress.self, forKey: .from)
        to = try container.decodeIfPresent([MailAddress].self, forKey: .to) ?? []
        cc = try container.decodeIfPresent([MailAddress].self, forKey: .cc) ?? []
        subject = try container.decode(String.self, forKey: .subject)
        date = try container.decode(Date.self, forKey: .date)
        isRead = try container.decode(Bool.self, forKey: .isRead)
        isStarred = try container.decode(Bool.self, forKey: .isStarred)
        labelIDs = try container.decodeIfPresent([String].self, forKey: .labelIDs) ?? []
        hasAttachments = try container.decodeIfPresent(Bool.self, forKey: .hasAttachments) ?? false
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        attachments = try container.decodeIfPresent([MailAttachment].self, forKey: .attachments) ?? []
    }
}
