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
    /// Replaces `losingIDs` with `thread`, whose id survives.
    ///
    /// `upsertThread` keys on a thread id the provider supplied and can only
    /// repair MONTH drift. With locally computed threading (IMAP has no
    /// server-side threads) a newly arrived message can link two previously
    /// separate threads, so the thread IDENTITY changes: the losing ids' thread
    /// documents and index rows have to go, or the inbox keeps ghost rows
    /// pointing at threads that no longer exist.
    ///
    /// Bodies are keyed by message id, never by thread, so a merge leaves every
    /// body exactly where it is. An unknown losing id is a no-op for that id:
    /// partial knowledge must not fail the whole merge.
    func mergeThreads(losingIDs: [String], into thread: MailThread) throws
    func removeThread(_ id: String, accountID: String, date: Date) throws

    func body(messageID: String) -> MessageBody?
    func saveBody(_ body: MessageBody, accountID: String) throws

    func labels(accountID: String) -> [MailLabel]
    func saveLabels(_ labels: [MailLabel], accountID: String) throws

    /// An `.imap` account's persisted mailbox set, or `nil` when none has been
    /// stored — which is the ordinary state for every non-IMAP account and for an
    /// IMAP account whose setup never completed a `LIST`.
    ///
    /// On the protocol rather than only on `DocumentMailStore` because
    /// `LabelVocabularyResolver.vocabulary(forAccountID:store:)` is the single
    /// place that decides whether an IMAP mutation may be rendered at all, and it
    /// is handed a `MailStore`. Reaching the directory by downcasting to the
    /// concrete store would make that decision depend on which store type the
    /// caller happened to pass: a conforming store that is not a
    /// `DocumentMailStore` would silently answer "no directory" and every IMAP
    /// mutation through it would be refused for a reason nothing states.
    func imapMailboxDirectory(accountID: String) -> IMAPMailboxDirectory?

    /// Records the mailbox set a `LIST` returned for `accountID`.
    func saveIMAPMailboxDirectory(_ directory: IMAPMailboxDirectory,
                                  accountID: String) throws

    /// The `label_with_reason` records this account holds inside the 90-day
    /// window, newest first; `threadID` narrows them to one thread.
    ///
    /// On the protocol rather than only on `DocumentMailStore` for
    /// `imapMailboxDirectory`'s reason: `RavenMCPOperations` is handed a
    /// `MailStore`, and reaching the log by downcasting would make whether an
    /// agent's reason is recorded at all depend on which store type the caller
    /// happened to pass.
    func labelReasons(accountID: String, threadID: String?) -> [LabelReason]

    /// Appends one reason record. Local-only: nothing here is ever attached to
    /// a `LabelMutation` or handed to a provider.
    func recordLabelReason(_ reason: LabelReason, accountID: String) throws
}
