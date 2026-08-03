import Foundation

public struct MessageBody: Codable, Equatable, Sendable {
    public let messageID: String
    public let plainText: String
    public let html: String?
    /// The raw `text/calendar` part's text, when the message carries a
    /// calendar invite/reply/cancellation — parsed by `ICalendar` for the
    /// invite card in `ThreadSurface`. `nil` for any message without one;
    /// decoded as `nil` for documents saved before M4.
    public let icsText: String?
    /// Whether this message carried a verifiable S/MIME signature. A DISTINCT
    /// enum case split, not a bool: `.signedInvalid` (tampered/broken
    /// signature) must never collapse into `.unsigned` (never signed at
    /// all) — they are different security postures. Defaults to `.unsigned`
    /// for every existing caller and every document persisted before S/MIME
    /// support shipped, so no other behavior changes.
    public let signatureStatus: SignatureStatus

    public init(messageID: String, plainText: String, html: String?, icsText: String? = nil,
                signatureStatus: SignatureStatus = .unsigned) {
        self.messageID = messageID; self.plainText = plainText; self.html = html
        self.icsText = icsText; self.signatureStatus = signatureStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try c.decode(String.self, forKey: .messageID)
        plainText = try c.decode(String.self, forKey: .plainText)
        html = try c.decodeIfPresent(String.self, forKey: .html)
        icsText = try c.decodeIfPresent(String.self, forKey: .icsText)
        signatureStatus = try c.decodeIfPresent(SignatureStatus.self, forKey: .signatureStatus) ?? .unsigned
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
    func saveBody(_ body: MessageBody, accountID: String) throws

    func labels(accountID: String) -> [MailLabel]
    func saveLabels(_ labels: [MailLabel], accountID: String) throws
}
