import Foundation

public struct MessageBody: Codable, Equatable, Sendable {
    public let messageID: String
    public let plainText: String
    public let html: String?

    public init(messageID: String, plainText: String, html: String?) {
        self.messageID = messageID; self.plainText = plainText; self.html = html
    }
}

@MainActor public protocol MailStore: AnyObject {
    func accounts() -> [MailAccount]
    func saveAccount(_ account: MailAccount) throws
    func removeAccount(_ id: String) throws
    /// Removes the account row AND every local document belonging to it.
    /// `removeAccount` alone leaves the mail readable on disk indefinitely.
    func purge(accountID: String) throws

    func summaries(accountID: String, months: [String]) -> [ThreadSummary]
    func upsertThread(_ thread: MailThread) throws
    func thread(_ id: String) -> MailThread?
    func removeThread(_ id: String, accountID: String, date: Date) throws

    func body(messageID: String) -> MessageBody?
    func saveBody(_ body: MessageBody) throws

    func labels(accountID: String) -> [MailLabel]
    func saveLabels(_ labels: [MailLabel], accountID: String) throws
}
