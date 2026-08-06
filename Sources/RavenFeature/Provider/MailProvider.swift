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

/// One file attached to an outbound message. Bytes are held in memory only
/// (matching the inbound `MailAttachment` contract of never caching to disk)
/// until `GmailProvider.rfc822` base64-encodes them into the outgoing MIME
/// structure.
public struct OutgoingAttachment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.data = data
    }
}

/// An RSVP reply to a calendar invite: a `text/calendar; method=REPLY` part
/// carrying the user's `PARTSTAT`, addressed to the invite's organizer. This
/// is the whole of "RSVP by email" — it travels between mail clients with no
/// calendar access on either side, which is exactly why it is in scope while
/// `EventKit` is not.
public struct ICSReply: Codable, Equatable, Sendable {
    /// The full `BEGIN:VCALENDAR…END:VCALENDAR` text, already carrying
    /// `METHOD:REPLY` and the chosen `PARTSTAT`.
    public let icsText: String

    public init(icsText: String) {
        self.icsText = icsText
    }
}

/// A message to transmit.
public struct OutgoingMessage: Codable, Equatable, Sendable {
    public let to: [MailAddress]
    public let cc: [MailAddress]
    /// Blind carbon copies. These recipients receive the message and **must
    /// not appear in the headers any other recipient can see** — that is the
    /// entire meaning of the field, and getting it wrong discloses a private
    /// distribution list.
    ///
    /// How that is achieved is provider-specific and is documented at the one
    /// place it happens, `GmailProvider.rfc822`: Gmail's `messages/send` takes
    /// the whole RFC822 message as `raw` and derives the envelope from its
    /// headers, so the `Bcc:` header MUST be present there for the copy to be
    /// delivered at all, and Gmail is the party that strips it before handing
    /// the message to each recipient. Omitting the header would silently drop
    /// the recipient; writing our own envelope is not an option this API
    /// offers.
    public let bcc: [MailAddress]
    public let subject: String
    /// The plain text of the body, verbatim — **required, and never removed.**
    ///
    /// Since M6 the composer also carries `richBody`, but this key stays the
    /// truth about what the `text/plain` part will say. It is what an older
    /// build reads: one that knows nothing of `richBody` decodes this, sends a
    /// correct plain-text message, and strands nothing. Removing it, or making
    /// it optional, would turn a rollback (or two builds against one document
    /// store) into an outbox that will not load — see `richBody`.
    public let bodyText: String
    /// The same body with its formatting, when the composer produced any.
    ///
    /// **One additive optional key.** `nil` for every message that predates M6,
    /// for everything `create_draft` produces (Sage supplies a `String` and
    /// cannot supply attributes), and for anything typed without formatting —
    /// and a `nil` rich body is exactly the case `MarkdownToHTML` keeps
    /// serving, so those messages' bytes on the wire are unchanged.
    ///
    /// **`richBody!.text == bodyText` is an invariant**, enforced at every
    /// entry point below rather than trusted: the initializer re-anchors the
    /// rich body's text to `bodyText`, so the two cannot disagree however this
    /// value was produced. `SendAttempt.withSignature` is the live hazard —
    /// that rebuild has already silently dropped `attachments` and `icsReply`
    /// once, and a field forgotten there is a shipped bug on this file.
    public let richBody: RichBody?
    /// Set when this is a reply, so the provider can thread it correctly.
    public let inReplyToMessageID: String?
    public let threadID: String?
    /// Files the user attached in Compose. Empty for every message that
    /// predates M4 and for every reply/forward that carries none — the
    /// message stays `multipart/alternative` exactly as before in that case.
    public let attachments: [OutgoingAttachment]
    /// Present only for an RSVP generated from a calendar invite card. When
    /// set, `GmailProvider.rfc822` adds one more MIME part carrying this
    /// text — never in place of the human-readable body, so a mail client
    /// with no calendar support still shows something legible.
    public let icsReply: ICSReply?
    /// Which of the user's accounts composed this message, and therefore which
    /// account's provider must transmit it and whose signature gets appended.
    ///
    /// M0 left this off the message entirely and relied on `OutboxEntry.
    /// accountID` — stamped from whichever account happened to be attached at
    /// `enqueue` — to stop a queued send crossing accounts. That was a safety
    /// net (refuse to send) rather than routing (send from the right mailbox),
    /// which is only adequate while exactly one account can be connected.
    /// `Outbox.enqueue` now treats this, when present, as the authoritative
    /// stamp for the entry.
    ///
    /// Optional, and decoded as `nil` when absent, so outbox entries persisted
    /// by an earlier build still decode rather than stranding a queued send.
    /// `nil` means "no account claimed it" — routable only when there is
    /// exactly one candidate.
    public let accountID: String?

    public init(to: [MailAddress], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                subject: String,
                bodyText: String, inReplyToMessageID: String? = nil,
                threadID: String? = nil, accountID: String? = nil,
                attachments: [OutgoingAttachment] = [], icsReply: ICSReply? = nil,
                richBody: RichBody? = nil) {
        self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        self.bodyText = bodyText; self.inReplyToMessageID = inReplyToMessageID
        self.threadID = threadID; self.accountID = accountID
        self.attachments = attachments; self.icsReply = icsReply
        self.richBody = Self.anchored(richBody, to: bodyText)
    }

    /// Keeps `richBody.text` equal to `bodyText`, always.
    ///
    /// `bodyText` is authoritative, so a rich body that disagrees with it is
    /// re-anchored to it rather than accepted or rejected: the spans are
    /// re-validated against the authoritative text by `RichBody.init`, which
    /// drops any run that no longer addresses real characters. The alternative
    /// — trusting the caller — makes the two fields two truths, and the first
    /// site to forget one (a rebuild that carries `bodyText` and not
    /// `richBody`, or the reverse) ships a message whose plain and HTML parts
    /// say different things.
    private static func anchored(_ rich: RichBody?, to bodyText: String) -> RichBody? {
        guard let rich else { return nil }
        guard rich.text != bodyText else { return rich }
        return RichBody(text: bodyText, spans: rich.spans)
    }

    /// Explicit member-wise decode/encode so documents persisted before M4
    /// (no `attachments`/`icsReply` keys) still decode — an outbox entry
    /// queued before this shipped must not fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        to = try c.decode([MailAddress].self, forKey: .to)
        cc = try c.decodeIfPresent([MailAddress].self, forKey: .cc) ?? []
        // Absent from every draft and outbox entry persisted before Bcc
        // existed — decoded as empty rather than throwing, for the same reason
        // `cc`/`attachments` are: a queued send must not fail to load.
        bcc = try c.decodeIfPresent([MailAddress].self, forKey: .bcc) ?? []
        subject = try c.decode(String.self, forKey: .subject)
        bodyText = try c.decode(String.self, forKey: .bodyText)
        inReplyToMessageID = try c.decodeIfPresent(String.self, forKey: .inReplyToMessageID)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
        attachments = try c.decodeIfPresent([OutgoingAttachment].self, forKey: .attachments) ?? []
        icsReply = try c.decodeIfPresent(ICSReply.self, forKey: .icsReply)
        // Lenient in BOTH senses, and deliberately so. Absent (every document
        // written before M6) decodes to `nil` and the message sends as plain
        // text. Present but unreadable — a future build's shape, a truncated
        // object — also decodes to `nil` rather than throwing, because this
        // type is what an outbox entry is made of: a throw here fails the
        // entry, and one failed entry used to take the entire send queue with
        // it. The worst case is a message that goes out unformatted; it is
        // never a message that quietly ceases to exist.
        richBody = Self.anchored(try? c.decodeIfPresent(RichBody.self, forKey: .richBody),
                                 to: bodyText)
    }

    /// The same message attributed to `accountID`. Used where the account is
    /// only known one layer up from where the message was built (Compose's
    /// from-picker, `create_draft`'s explicit `account_id`, a reply resolving
    /// the account from its thread).
    public func attributed(to accountID: String?) -> OutgoingMessage {
        OutgoingMessage(to: to, cc: cc, bcc: bcc, subject: subject, bodyText: bodyText,
                        inReplyToMessageID: inReplyToMessageID, threadID: threadID,
                        accountID: accountID, attachments: attachments, icsReply: icsReply,
                        richBody: richBody)
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

/// Whether a backend's provider can transmit/mutate, or only read.
///
/// Added when Apple Mail import shipped as the first read-only backend: every
/// conformer before it (Gmail) assumed it could `send`/`applyLabels`, and that
/// assumption was never expressed in the type system — a read-only backend
/// could only refuse those calls at runtime, by throwing. Expressing it here
/// instead lets `MailProviderRouter` refuse a mutation BEFORE it ever reaches
/// the provider, for every backend, without each one having to remember to
/// guard its own `send`/`applyLabels`.
public enum MailProviderCapabilities: Equatable, Sendable {
    case readOnly
    case readWrite
}

/// Everything a backend must do. One conformer per backend; Gmail is first.
public protocol MailProvider: Sendable {
    var accountID: String { get }
    /// `.readWrite` for every backend that predates this — Gmail included —
    /// so this is a non-breaking addition to every existing conformer.
    var capabilities: MailProviderCapabilities { get }

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

    /// Full-archive search delegated to the provider — the one path that
    /// reaches beyond whatever window `SyncEngine` has synced locally. Called
    /// only on a deliberate "search all mail" act, never per keystroke; local
    /// search (`ThreadSearch`) stays purely in-memory and never calls this.
    ///
    /// The raw `query` string is passed straight through with no translation
    /// layer: Gmail's `q` syntax (from:, label:, is:unread, and much more) is
    /// close to, but not identical with, what `ThreadSearch.parse` accepts
    /// locally. Gmail's syntax is authoritative for what actually matches a
    /// remote hit — this does not attempt to reconcile the two grammars.
    func searchThreads(query: String, limit: Int) async throws -> [MailThread]
}
