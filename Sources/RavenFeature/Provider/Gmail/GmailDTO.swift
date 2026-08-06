import Foundation

/// Wire shapes for Gmail REST v1. These decode exactly what Google sends;
/// `GmailMapping` turns them into the domain model.
public struct GmailThreadDTO: Decodable {
    public let id: String
    public let historyId: String?
    public let messages: [GmailMessageDTO]?

    public init(id: String, historyId: String?, messages: [GmailMessageDTO]?) {
        self.id = id; self.historyId = historyId; self.messages = messages
    }
}

public struct GmailMessageDTO: Decodable {
    public struct Header: Decodable {
        public let name: String
        public let value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    public struct Body: Decodable {
        public let data: String?
        public let size: Int?
        /// Present only when this part's bytes are NOT inlined in `data` and
        /// must be fetched separately via `messages.attachments.get`.
        public let attachmentId: String?
        public init(data: String?, size: Int?, attachmentId: String? = nil) {
            self.data = data; self.size = size; self.attachmentId = attachmentId
        }
    }
    public struct Payload: Decodable {
        public let headers: [Header]
        public let mimeType: String?
        public let filename: String?
        public let body: Body?
        public let parts: [Payload]?
        public init(headers: [Header], mimeType: String?, filename: String? = nil,
                    body: Body?, parts: [Payload]?) {
            self.headers = headers; self.mimeType = mimeType; self.filename = filename
            self.body = body; self.parts = parts
        }
    }

    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let internalDate: String?
    public let payload: Payload?

    public init(id: String, threadId: String, labelIds: [String]?, snippet: String?,
                internalDate: String?, payload: Payload?) {
        self.id = id; self.threadId = threadId; self.labelIds = labelIds
        self.snippet = snippet; self.internalDate = internalDate; self.payload = payload
    }
}

public struct GmailListDTO: Decodable {
    public struct Ref: Decodable { public let id: String }
    public let threads: [Ref]?
    public let nextPageToken: String?
}

public struct GmailHistoryDTO: Decodable {
    public struct Entry: Decodable {
        public struct MessageRef: Decodable {
            public struct Message: Decodable { public let threadId: String }
            public let message: Message
        }
        public let messagesAdded: [MessageRef]?
        public let messagesDeleted: [MessageRef]?
        public let labelsAdded: [MessageRef]?
        public let labelsRemoved: [MessageRef]?
    }
    /// Absent entirely when nothing has changed since `startHistoryId`
    /// (confirmed against the real `history.json` fixture, which has only
    /// `historyId`) — `fetchDelta` must treat that as an empty delta, not a
    /// decoding failure.
    public let history: [Entry]?
    public let historyId: String?
}

public struct GmailLabelsDTO: Decodable {
    public struct Label: Decodable {
        public let id: String
        public let name: String
        public let type: String?
    }
    public let labels: [Label]?
}

public struct GmailProfileDTO: Decodable {
    public let historyId: String
}
