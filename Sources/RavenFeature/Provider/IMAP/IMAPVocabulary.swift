import Foundation

/// IMAP's `LabelVocabulary`: canonical flags ↔ the two *different* kinds of string
/// an IMAP server understands.
///
/// Gmail's vocabulary is the identity mapping because Gmail has exactly one kind
/// of string — a label. IMAP has two, and they are not interchangeable:
///
/// - **System flags** (`\Flagged`, `\Draft`, `\Deleted`), set with `UID STORE`.
/// - **Mailbox names** (`INBOX`, `Archive`, a user's `Folder A`), changed by
///   *moving* the message with `UID MOVE`/`UID COPY`.
///
/// The names are taken from the account's live `IMAPMailboxDirectory` rather than
/// re-derived here, which is the whole reason this type takes one. A second
/// name-guessing table would be a second chance to aim a delete at the wrong
/// folder, and `IMAPMailboxList` already documents at length why its heuristics
/// are as narrow as they are.
///
/// ## `\Unseen`, and why the read flag is inverted here rather than at the wire
///
/// The domain's canonical flag is `.unread` (see `MailFlag.unread` for why that
/// polarity was chosen), and IMAP's stored flag is `\Seen` — the opposite. A
/// vocabulary that rendered `.unread` as `"\\Seen"` would turn "mark unread" into
/// "mark read": `ThreadAction.setRead(false)` emits `add: [.unread]`, which would
/// arrive at the server as `+FLAGS (\Seen)`.
///
/// `LabelVocabulary` is a pure string mapping with no room to express an
/// inversion, so the rendered string is the *pseudo-flag* `\Unseen` — a name IMAP
/// uses as a SEARCH key and never as a message flag, so it cannot collide with a
/// real one. `IMAPProvider.applyLabels` is the single place that knows `\Unseen`
/// means "operate on `\Seen` with the opposite sign", and
/// `IMAPVocabularyTests` pins both halves.
///
/// ## Why `LabelVocabularyResolver` still answers `nil` for `.imap`
///
/// Deliberately unchanged by this task, and it is not an oversight. Every string
/// this type can produce for `.inbox`/`.archive`/`.trash`/`.sent`/`.spam` comes
/// from the account's mailbox directory, which only a live, `LIST`ed session has.
/// The static resolver has no session, and the seemingly harmless fallback — an
/// empty directory — is the dangerous one: `ThreadAction.archive` renders to
/// `remove: [.inbox]`, an empty directory drops it, and the user gets an empty
/// mutation that the UI reports as a successful archive while nothing moves. A
/// refusal is recoverable; a silent no-op that looks like success is not. Wiring
/// the resolver needs the mailbox list persisted per account, which is Task 16's
/// account-setup work.
struct IMAPVocabulary: LabelVocabulary {
    let directory: IMAPMailboxDirectory

    /// The pseudo-flag for `.unread`. Not a real IMAP message flag — IMAP has
    /// `\Seen` and no negation of it — so it can never be confused with something
    /// a server sent.
    static let unseenPseudoFlag = "\\Unseen"

    init(directory: IMAPMailboxDirectory = IMAPMailboxDirectory([])) {
        self.directory = directory
    }

    /// Canonical flags whose IMAP spelling is a system flag rather than a mailbox.
    /// The one place the mapping is written; `isSystemFlag` reads it back so the
    /// two directions cannot drift.
    private static let systemFlags: [String: MailFlag] = [
        unseenPseudoFlag: .unread,
        "\\Flagged": .starred,
        "\\Draft": .draft,
    ]

    /// Whether a rendered string is a system flag (`UID STORE`) rather than a
    /// mailbox name (`UID MOVE`). Structural — a leading backslash is exactly what
    /// RFC 3501 reserves for system flags and forbids in a mailbox name — so a
    /// server-defined flag this build has never heard of still routes to `STORE`.
    static func isSystemFlag(_ label: String) -> Bool { label.hasPrefix("\\") }

    func label(for flag: MailFlag) -> String? {
        switch flag {
        case .unread: return Self.unseenPseudoFlag
        case .starred: return "\\Flagged"
        case .draft: return "\\Draft"
        // Folder-valued flags. `nil` when the account has no such mailbox, and
        // that nil is load-bearing: `IMAPMailboxDirectory.mailbox(for:)` refuses
        // to guess a name, and inventing `"Archive"` here would undo it and aim a
        // move at a mailbox that does not exist.
        case .inbox, .archive, .trash, .spam, .sent:
            return directory.mailbox(for: flag)?.name
        // Either an IMAP keyword the server defined or a mailbox name a caller
        // supplied (`ThreadAction.label`). Carried through verbatim; which of the
        // two it is is decided by `isSystemFlag`, on the string itself.
        case .user(let name): return name
        }
    }

    func flag(for label: String) -> MailFlag {
        if let flag = Self.systemFlags[label] { return flag }
        // `\Deleted` is IMAP's "marked for expunge", which is what `.trash` means
        // canonically — the same reading `IMAPFetchParser.canonicalFlags` gives it.
        if label.caseInsensitiveCompare("\\Deleted") == .orderedSame { return .trash }
        if label.caseInsensitiveCompare("\\Seen") == .orderedSame {
            // Never rendered by this type, but a server can send it and a caller
            // can store it. `.user` rather than `.unread`: reading `\Seen` as
            // "unread" is the inversion bug this file exists to prevent, and there
            // is no canonical flag for the positive polarity.
            return .user(label)
        }
        for candidate in Self.systemFlags.keys
        where candidate.caseInsensitiveCompare(label) == .orderedSame {
            return Self.systemFlags[candidate] ?? .user(label)
        }
        guard !Self.isSystemFlag(label) else { return .user(label) }
        // A mailbox name the directory knows reads as that mailbox's canonical
        // meaning; anything else is a user label, never dropped.
        return directory.flag(for: label)
    }
}
