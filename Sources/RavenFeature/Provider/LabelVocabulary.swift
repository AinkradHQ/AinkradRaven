import Foundation

/// Translates between the domain's canonical `MailFlag` set and one backend's
/// own label/flag/folder strings.
///
/// One conformer per backend. The domain never writes a provider string; it
/// emits `MailFlag`s and asks the account's vocabulary to render them. That
/// keeps `ThreadAction`, `ThreadMutationApplier` and `InboxFilter` — all shared
/// by the human UI and the MCP write tools — free of any one provider's
/// spelling.
///
/// Rendering direction (`label(for:)`) may legitimately return `nil`: a flag
/// can be unrepresentable as a label on a given backend. Gmail's `archive` is
/// exactly that case — archiving on Gmail is the *removal* of `INBOX`, not the
/// addition of anything — so a `nil` is dropped from the rendered mutation
/// rather than being turned into a bogus label.
public protocol LabelVocabulary: Sendable {
    /// This backend's string for `flag`, or `nil` when the backend has no
    /// label for it.
    func label(for flag: MailFlag) -> String?

    /// The canonical meaning of one of this backend's strings. Anything with
    /// no canonical meaning comes back as `.user(label)` rather than being
    /// dropped — a label the domain does not understand is still a label the
    /// user can see and the provider must keep.
    func flag(for label: String) -> MailFlag
}

extension LabelVocabulary {
    /// Renders a canonical mutation into the provider-string `LabelMutation`
    /// the outbox persists and the provider applies. Order is preserved so the
    /// rendered strings are stable and directly assertable.
    public func render(_ mutation: FlagMutation) -> LabelMutation {
        LabelMutation(threadIDs: mutation.threadIDs,
                      add: mutation.add.compactMap(label(for:)),
                      remove: mutation.remove.compactMap(label(for:)))
    }

    /// The canonical reading of a stored label list. This is how read/starred
    /// state is derived now, instead of testing a stored label list against
    /// one provider's unread label.
    public func flags(from labels: [String]) -> Set<MailFlag> {
        Set(labels.map(flag(for:)))
    }

    public func flags<S: Sequence>(from labels: S) -> Set<MailFlag> where S.Element == String {
        Set(labels.map(flag(for:)))
    }

    /// Whether a stored label list means "not yet read", per this backend.
    public func isUnread(labels: [String]) -> Bool {
        flags(from: labels).contains(.unread)
    }

    /// Whether a stored label list means "starred"/"flagged", per this backend.
    public func isStarred(labels: [String]) -> Bool {
        flags(from: labels).contains(.starred)
    }
}

/// Gmail's vocabulary — and, deliberately, **the identity mapping**.
///
/// Every canonical flag renders to exactly the string the pre-canonical code
/// hardcoded, and every one of Gmail's system labels reads back to the flag it
/// always meant. That is what makes this refactor provably behaviour-preserving
/// for the only backend that currently ships: `MailFlagVocabularyTests` asserts
/// the rendered `LabelMutation`s byte-for-byte against the values
/// `ThreadAction.mutation` produced before the change.
///
/// This type is the ONLY place in `Sources/` allowed to spell Gmail's label
/// strings. If a Gmail literal appears anywhere else, the domain has started
/// speaking Gmail again.
public struct GmailVocabulary: LabelVocabulary {
    public init() {}

    public func label(for flag: MailFlag) -> String? {
        switch flag {
        case .inbox: return "INBOX"
        case .unread: return "UNREAD"
        case .starred: return "STARRED"
        case .trash: return "TRASH"
        case .spam: return "SPAM"
        case .sent: return "SENT"
        case .draft: return "DRAFT"
        // Gmail archives by REMOVING `INBOX`; there is no archive label to
        // add. Returning nil (and being dropped) is correct, and matches what
        // `ThreadAction.archive` has always emitted: a bare `remove: [INBOX]`.
        case .archive: return nil
        case .user(let name): return name
        }
    }

    public func flag(for label: String) -> MailFlag {
        switch label {
        case "INBOX": return .inbox
        case "UNREAD": return .unread
        case "STARRED": return .starred
        case "TRASH": return .trash
        case "SPAM": return .spam
        case "SENT": return .sent
        case "DRAFT": return .draft
        // Everything else — `CATEGORY_*`, `IMPORTANT`, `Label_17`, a
        // user-created label — is carried through verbatim.
        default: return .user(label)
        }
    }
}

/// The vocabulary to use when no account-specific one has been resolved.
///
/// Gmail is the only backend that currently reaches the shared mutation path,
/// so Gmail's identity mapping is the default and today's behaviour is
/// unchanged everywhere. IMAP's and Graph's vocabularies arrive with their
/// providers, and the call sites below take an explicit `vocabulary:` argument
/// so wiring them per account is a caller change, not a rewrite of the domain.
public let defaultLabelVocabulary: LabelVocabulary = GmailVocabulary()

/// Which vocabulary an account's stored labels are written in.
///
/// This exists because the alternative is silent corruption. Every mutation
/// site used to take `vocabulary:` with a Gmail default, which meant a future
/// `IMAPProvider` could land with **no compile error anywhere** and archiving an
/// IMAP thread would enqueue `remove: ["INBOX"]` — a Gmail label handed to a
/// server that has never heard of it. Resolving per account instead makes an
/// unknown backend a *refusal*, and a refusal is recoverable in a way a
/// mailbox mutated through the wrong vocabulary is not.
///
/// Returning `nil` rather than falling back to Gmail is the whole point: a
/// fallback is exactly the bug. When Tasks 13 and 20 add `IMAPVocabulary` and
/// `GraphVocabulary`, they add the cases here and every mutation site starts
/// working with no further wiring.
public enum LabelVocabularyResolver {
    /// `nil` means "this build cannot safely express mutations for that
    /// backend". Callers must refuse, never guess.
    public static func vocabulary(for kind: MailAccount.ProviderKind) -> LabelVocabulary? {
        switch kind {
        case .gmail:
            return GmailVocabulary()
        case .appleMail:
            // Safe, and worth stating why rather than leaving it to look like a
            // fallback: `AppleMailImporter` emits `labelIDs: []` for every
            // imported message, so there are no provider strings to translate
            // in either direction. The account is also read-only —
            // `MailProviderRouter.writableProvider` refuses its sends — so no
            // mutation is ever rendered for it. If Apple Mail ever grows real
            // labels, this needs its own vocabulary.
            return GmailVocabulary()
        case .imap, .graph:
            // Deliberately unresolved until Tasks 13 and 20 ship the real
            // vocabularies. `MailFlagVocabularyTests` pins this nil, so adding
            // a vocabulary without revisiting that test is a build failure
            // rather than a surprise in production.
            return nil
        case .unsupported:
            return nil
        }
    }

    /// The vocabulary for a stored account id, or `nil` when the account is
    /// unknown to the store as well as when its backend is unsupported — an
    /// unknown account is precisely the case where guessing is least defensible.
    @MainActor
    public static func vocabulary(forAccountID accountID: String?,
                                  store: MailStore) -> LabelVocabulary? {
        guard let accountID else { return nil }
        guard let account = store.accounts().first(where: { $0.id == accountID }) else { return nil }
        return vocabulary(for: account.provider)
    }
}
