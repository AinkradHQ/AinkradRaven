import Foundation

/// One page of a backfill walk.
public struct ThreadPage: Equatable, Sendable {
    public let threads: [MailThread]
    public let nextPageToken: String?
    public init(threads: [MailThread], nextPageToken: String?) {
        self.threads = threads; self.nextPageToken = nextPageToken
    }
}

/// What changed since a cursor.
public struct MailDelta: Equatable, Sendable {
    public let changedThreadIDs: [String]
    public let removedThreadIDs: [String]
    public let newCursor: String
    public init(changedThreadIDs: [String], removedThreadIDs: [String], newCursor: String) {
        self.changedThreadIDs = changedThreadIDs
        self.removedThreadIDs = removedThreadIDs
        self.newCursor = newCursor
    }
}

/// A message to transmit.
public struct OutgoingMessage: Codable, Equatable, Sendable {
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let subject: String
    public let bodyText: String
    /// Set when this is a reply, so the provider can thread it correctly.
    public let inReplyToMessageID: String?
    public let threadID: String?

    public init(to: [MailAddress], cc: [MailAddress] = [], subject: String,
                bodyText: String, inReplyToMessageID: String? = nil,
                threadID: String? = nil) {
        self.to = to; self.cc = cc; self.subject = subject
        self.bodyText = bodyText; self.inReplyToMessageID = inReplyToMessageID
        self.threadID = threadID
    }
}

public struct LabelMutation: Codable, Equatable, Sendable {
    public let threadIDs: [String]
    public let add: [String]
    public let remove: [String]
    public init(threadIDs: [String], add: [String] = [], remove: [String] = []) {
        self.threadIDs = threadIDs; self.add = add; self.remove = remove
    }
}

/// Everything a backend must do. One conformer per backend; Gmail is first.
public protocol MailProvider: Sendable {
    var accountID: String { get }

    /// Newest-first page walk, bounded by `since`.
    func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage
    /// What changed since `cursor`. Throws `.providerFailed` when the cursor is
    /// too old to serve, which the caller answers with a full backfill.
    func fetchDelta(cursor: String) async throws -> MailDelta
    func fetchThread(id: String) async throws -> MailThread
    func fetchBody(messageID: String) async throws -> MessageBody
    /// Fetches one attachment's raw bytes on demand. Never cached by the
    /// caller to disk — see `RavenRuntime.fetchAttachment`.
    func fetchAttachment(messageID: String, attachmentID: String) async throws -> Data
    func fetchLabels() async throws -> [MailLabel]
    func applyLabels(_ mutation: LabelMutation) async throws
    func send(_ message: OutgoingMessage) async throws -> String  // provider message id
    /// The newest cursor available right now, for seeding after a backfill.
    func currentCursor() async throws -> String
}
