import Foundation

/// The canonical, provider-independent vocabulary for the states a mail
/// message can be in.
///
/// Gmail's label strings had leaked into shared domain code as literals:
/// `ThreadAction.mutation` emitted Gmail's four system label strings directly,
/// `ThreadMutationApplier.applyLocally` derived read state by testing the
/// stored labels for Gmail's unread label, and `InboxFilter` decided "is this
/// in the inbox" the same way. That code sits on the mutation path for BOTH the human
/// UI and every MCP write tool, so an IMAP account (which has `\Seen`,
/// `\Flagged` and *folders*) or a Graph account (which has `isRead` plus
/// folders plus categories) driven through it would have corrupted state.
///
/// The domain now speaks `MailFlag`; each backend owns a `LabelVocabulary`
/// that translates in both directions. Gmail's translation is the identity, so
/// Gmail's behaviour is unchanged.
///
/// **This is a mutation-time vocabulary, NOT a storage change.** Labels stay
/// STORED on `MailMessage.labelIDs` / `ThreadSummary.labelIDs` as the
/// provider's own strings, exactly as before, and `LabelMutation` — which the
/// outbox persists and the provider receives — still carries provider strings.
/// Existing `thread-*` documents therefore decode and render identically.
/// Do not "finish the job" by migrating stored labels to canonical flags:
/// the stored strings are the provider's truth for round-tripping mutations
/// back to that provider, and rewriting them would require a document
/// migration that buys nothing.
public enum MailFlag: Hashable, Sendable, Codable {
    /// Present in the account's primary incoming view.
    case inbox
    /// NOT yet read. Deliberately the *unread* polarity rather than `read`,
    /// because Gmail and IMAP disagree on which direction is the stored one
    /// (`UNREAD` label vs `\Seen` flag) and a canonical `read` would have made
    /// Gmail's mapping a negation instead of the identity.
    case unread
    case starred
    case trash
    case spam
    case sent
    case draft
    /// Filed out of the inbox but not deleted. Gmail has no label for this —
    /// archiving is the *removal* of `inbox` — so `GmailVocabulary` maps it to
    /// no label at all. Folder-based backends (IMAP, Graph) map it to a real
    /// mailbox.
    case archive
    /// Any provider label with no canonical meaning: a Gmail user label, an
    /// IMAP keyword or non-special-use mailbox, a Graph category. Carried
    /// through verbatim.
    case user(String)

    /// A stable, provider-independent token. Used for `Codable` and for
    /// diagnostics; never written into a stored label list.
    public var canonicalToken: String {
        switch self {
        case .inbox: return "inbox"
        case .unread: return "unread"
        case .starred: return "starred"
        case .trash: return "trash"
        case .spam: return "spam"
        case .sent: return "sent"
        case .draft: return "draft"
        case .archive: return "archive"
        case .user(let name): return "user:\(name)"
        }
    }

    public init(canonicalToken token: String) {
        switch token {
        case "inbox": self = .inbox
        case "unread": self = .unread
        case "starred": self = .starred
        case "trash": self = .trash
        case "spam": self = .spam
        case "sent": self = .sent
        case "draft": self = .draft
        case "archive": self = .archive
        default:
            if let name = token.hasPrefix("user:") ? String(token.dropFirst(5)) : nil {
                self = .user(name)
            } else {
                // Forward compatibility, the same rule `OutgoingMessage`'s
                // decoder follows: a token a future build understands decodes
                // to a usable value here rather than throwing.
                self = .user(token)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let token = try decoder.singleValueContainer().decode(String.self)
        self.init(canonicalToken: token)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalToken)
    }
}

/// A thread mutation expressed in canonical flags — what `ThreadAction`
/// produces. A `LabelVocabulary` renders it into the provider-string
/// `LabelMutation` the outbox stores and the provider applies.
public struct FlagMutation: Equatable, Sendable {
    public let threadIDs: [String]
    public let add: [MailFlag]
    public let remove: [MailFlag]

    public init(threadIDs: [String], add: [MailFlag] = [], remove: [MailFlag] = []) {
        self.threadIDs = threadIDs
        self.add = add
        self.remove = remove
    }
}
