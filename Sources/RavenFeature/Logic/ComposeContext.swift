import Foundation

/// The thread a reply/forward is being composed against, reduced to exactly
/// the three facts a send needs. A snapshot rather than the live `MailThread`
/// so the composing surface cannot accidentally re-derive routing from a
/// thread that has since been archived out from under it.
public struct ComposeThreadReference: Equatable, Sendable {
    public let threadID: String
    /// The account the thread lives in — the account a reply must go out
    /// from. Never "the" account: replying from the wrong mailbox is the
    /// defect `RavenRuntime.ownAddress(for:)` exists to prevent.
    public let accountID: String
    /// `rfc822MessageID` of the message being replied to, for `In-Reply-To`.
    public let lastMessageRFC822ID: String?

    public init(threadID: String, accountID: String, lastMessageRFC822ID: String?) {
        self.threadID = threadID
        self.accountID = accountID
        self.lastMessageRFC822ID = lastMessageRFC822ID
    }
}

/// What the one composing overlay is currently composing.
///
/// Compose used to be a surface of its own and Reply/Reply-all/Forward an
/// inline panel on the Thread surface, each with its own copy of "turn typed
/// text into an `OutgoingMessage`". There is now one overlay, so the part that
/// genuinely differs between them — the threading and routing stamps — lives
/// here, out of the view and under test.
public enum ComposeContext: Equatable, Sendable {
    /// A brand-new message. Its account comes from the From picker /
    /// `RavenRuntime.composingAccountID`, and it threads onto nothing.
    case new
    /// A reply, reply-all, or forward of `thread`.
    case reply(mode: ReplyComposer.Mode, thread: ComposeThreadReference)

    /// The thread this context replies to, if any.
    public var thread: ComposeThreadReference? {
        switch self {
        case .new: return nil
        case .reply(_, let thread): return thread
        }
    }

    /// Whether a send from this context joins an existing conversation.
    ///
    /// A forward deliberately does NOT: it is a new conversation addressed to
    /// somebody who was never on the original, so stamping the original's
    /// `threadID`/`In-Reply-To` on it would file the forward back into a
    /// thread its recipient cannot see. This mirrors exactly what the old
    /// inline `ReplyPanel` did (`mode == .forward ? nil : …`).
    public var threadsOntoExistingConversation: Bool {
        switch self {
        case .new: return false
        case .reply(let mode, _): return mode != .forward
        }
    }

    /// Applies this context's threading and routing stamps to a message the
    /// composer built from typed text.
    ///
    /// `fallbackAccountID` is used only for `.new` — a reply is always
    /// attributed to the thread's own account, never to the From picker, so a
    /// reply can never leave from a mailbox that was not part of the
    /// conversation.
    public func stamp(_ message: OutgoingMessage,
                      fallbackAccountID: String?) -> OutgoingMessage {
        guard let thread else { return message.attributed(to: fallbackAccountID) }
        let threads = threadsOntoExistingConversation
        return OutgoingMessage(
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            subject: message.subject,
            bodyText: message.bodyText,
            inReplyToMessageID: threads ? thread.lastMessageRFC822ID : nil,
            threadID: threads ? thread.threadID : nil,
            accountID: thread.accountID,
            attachments: message.attachments,
            icsReply: message.icsReply)
    }
}
