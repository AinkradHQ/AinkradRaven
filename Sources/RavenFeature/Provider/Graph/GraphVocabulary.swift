import Foundation

/// Microsoft Graph's `LabelVocabulary`: canonical flags ↔ the **three** kinds of
/// string a Graph mailbox understands.
///
/// Gmail's vocabulary is the identity mapping because Gmail has one kind of string.
/// IMAP has two (system flags, mailbox names). Graph has three, and no two of them
/// are applied by the same request:
///
/// - **Message properties**, set with `PATCH /me/messages/{id}`: `isRead` for
///   read state, `flag.flagStatus` for the star.
/// - **Folders**, changed by *moving* the message with
///   `POST /me/messages/{id}/move`.
/// - **Categories**, the user-label equivalent, set by rewriting the message's
///   `categories` array on the same `PATCH`.
///
/// `GraphMutations.applyLabels` is the single place that turns a rendered string
/// back into one of those three requests, and it decides which purely from the
/// string's own shape — the prefixes below — never from a table it keeps in
/// parallel with this one.
///
/// ## Why this vocabulary needs no directory, where IMAP's does
///
/// `IMAPVocabulary` takes an `IMAPMailboxDirectory` because IMAP folder names are
/// arbitrary per server: an account may have no archive folder at all, so
/// `label(for: .archive)` can legitimately answer `nil` and a *missing* directory
/// is indistinguishable from an empty one. Graph is not like that.
/// `wellKnownName` is Graph's own stable, locale-independent identifier for the
/// folders the service itself owns, it is accepted verbatim as `destinationId` on
/// `/move`, and every mailbox has the full set. So every folder-valued flag here
/// renders to a string that is guaranteed to resolve server-side, there is no
/// silent-drop hazard of the kind `LabelVocabularyResolver.imapVocabulary`
/// exists to refuse, and the kind-only
/// `LabelVocabularyResolver.vocabulary(for: .graph)` can answer with this type.
///
/// That is a claim about Graph, not a relaxation of the rule. The rule —
/// *a backend with no vocabulary must refuse rather than guess* — is unchanged and
/// still pins `.imap` and `.unsupported` to `nil` on that overload.
///
/// ## Why folders carry a reserved prefix, and why that prefix starts with U+0001
///
/// A bare `"archive"` would be a rendered label that a user-created **category**
/// could equal exactly. `MailFlag.user("archive")` and `MailFlag.archive` would
/// then render to the same string, `flag(for:)` would read both back as
/// `.archive`, and applying the user's own category would MOVE their mail.
///
/// A plain `"folder:"` prefix does not fully close that: `MailFlag.user` names are
/// arbitrary caller strings (the MCP `label` tool, a `MailRule`), so a caller could
/// supply `folder:archive` and land in exactly the same place. Two things make the
/// three kinds genuinely disjoint rather than merely usually-disjoint:
///
/// 1. The marker begins with **U+0001**, a C0 control character. It cannot be typed
///    into a category name in any mail client, it is not valid in an Outlook
///    category display name, and no string Graph sends contains one — so a category
///    cannot *accidentally* wear the marker.
/// 2. A `.user` name that wears the marker anyway — or that equals one of the two
///    pseudo-flags — is **refused by `label(for:)`** (returns `nil`, dropped by
///    `LabelVocabulary.render`) rather than rendered. So a *deliberately* crafted
///    label cannot be turned into a folder move either. Dropping is safe here in a
///    way it is not for IMAP's folders: the mutation that survives is one the
///    account can perform, and the label that was refused is not one Graph could
///    have stored under that name in the first place.
///
/// `GraphVocabularyTests.kindsAreDisjoint` and
/// `reservedCategoryNamesAreRefusedRatherThanRendered` pin both halves.
/// `IMAPVocabulary.isSystemFlag` gets the same property for free from RFC 3501
/// reserving a leading backslash; Graph reserves nothing, so this type has to.
///
/// ## `isRead`, and why the read flag is inverted at the request rather than here
///
/// The domain's canonical flag is `.unread`; Graph's stored property is the
/// opposite polarity, `isRead`. `LabelVocabulary` is a pure string mapping with no
/// room to express an inversion, so — exactly as `IMAPVocabulary` does for `\Seen`
/// — the rendered string is a *pseudo-flag*, `\Unread`, and
/// `GraphMutations.applyLabels` is the one place that knows adding it means
/// `isRead: false`. Rendering `.unread` as something named for `isRead` would turn
/// "mark unread" into "mark read", because `ThreadAction.setRead(false)` emits
/// `add: [.unread]`.
///
/// ## Known consequence: a folder move is not reflected in the LOCAL labels
///
/// `GraphMapping.labelIDs` stores a message's `parentFolderId` — an opaque Graph
/// id — plus its categories. The strings this type renders for folders are
/// `wellKnownName`s, not ids, so `ThreadMutationApplier.applyLocally` removing
/// `folder:inbox` from a stored label list removes nothing, and an archived thread
/// keeps its old folder id until the next sync re-reads it. Read state, the star
/// and categories DO round-trip locally, because those rendered strings are
/// exactly what this type reads back.
///
/// Stated rather than papered over: making the local half exact needs
/// `GraphMapping` to store a well-known token instead of a folder id, which needs
/// the folder listing at mapping time. That is a read-path change and is not this
/// task's. Nothing here guesses in the meantime — the *remote* move is correct,
/// which is the half that cannot be re-derived.
struct GraphVocabulary: LabelVocabulary {
    init() {}

    /// The pseudo-flag for `.unread`. Not a Graph property name and not a
    /// `wellKnownName`, so it can never be confused with something Graph sent.
    static let unreadPseudoFlag = "\\Unread"
    /// The star. Graph spells it `flag.flagStatus == "flagged"`; the rendered
    /// string is the flag-shaped name so both live under the same prefix rule.
    static let flaggedFlag = "\\Flagged"

    /// Prefix marking a rendered string as a folder `wellKnownName` rather than a
    /// category.
    ///
    /// The leading U+0001 is load-bearing, not decoration — see the type's
    /// documentation. A readable `"folder:"` would be a string a caller could
    /// supply as a user label, and `label(for:)` would then render a category
    /// indistinguishable from a folder move.
    static let folderPrefix = "\u{1}folder:"

    /// Whether a rendered string is a message property (`PATCH`) rather than a
    /// folder or a category. Structural, matching `IMAPVocabulary.isSystemFlag`.
    static func isSystemFlag(_ label: String) -> Bool { label.hasPrefix("\\") }

    /// The `wellKnownName` inside a rendered folder string, or `nil` when the
    /// string is not a folder at all. This — not a second table of names — is how
    /// `GraphMutations` finds a `/move` destination.
    static func wellKnownFolder(in label: String) -> String? {
        guard label.hasPrefix(folderPrefix) else { return nil }
        let name = String(label.dropFirst(folderPrefix.count))
        return name.isEmpty ? nil : name
    }

    /// Whether a rendered string is a category, i.e. neither of the other two.
    static func isCategory(_ label: String) -> Bool {
        !isSystemFlag(label) && wellKnownFolder(in: label) == nil
    }

    /// Whether a caller-supplied `MailFlag.user` name would be indistinguishable
    /// from a folder or a property write once rendered, and must therefore be
    /// refused instead.
    ///
    /// Narrow on purpose. It is NOT "starts with a backslash": `IMAPVocabulary`
    /// carries server-defined keywords through verbatim and a category beginning
    /// with `\` is a legal Outlook category, so refusing all of them would drop
    /// labels that are perfectly safe. Only the two exact pseudo-flags collide.
    static func isReserved(_ name: String) -> Bool {
        name.hasPrefix(folderPrefix) || name == unreadPseudoFlag || name == flaggedFlag
    }

    /// Graph's `wellKnownName` for each folder-valued canonical flag.
    ///
    /// These are Graph's own identifiers, not display names, and they are what
    /// `/move`'s `destinationId` accepts. `deleteditems` and `junkemail` are the
    /// two that do not read like their canonical flag; spelling either as `trash`
    /// or `spam` produces a 404 on every move.
    private static let folders: [MailFlag: String] = [
        .inbox: "inbox",
        .archive: "archive",
        .trash: "deleteditems",
        .spam: "junkemail",
        .sent: "sentitems",
        .draft: "drafts",
    ]

    /// The reverse of `folders`, built from it so the two cannot drift.
    private static let flagsByFolder: [String: MailFlag] = {
        var reversed: [String: MailFlag] = [:]
        for (flag, name) in folders { reversed[name] = flag }
        return reversed
    }()

    func label(for flag: MailFlag) -> String? {
        switch flag {
        case .unread: return Self.unreadPseudoFlag
        case .starred: return Self.flaggedFlag
        // Never `nil`: every Graph mailbox has all six well-known folders, so
        // unlike IMAP there is no account for which one of these is
        // unrepresentable. See the type's documentation.
        case .inbox, .archive, .trash, .spam, .sent, .draft:
            return Self.folders[flag].map { Self.folderPrefix + $0 }
        // A category. Carried through verbatim — unless it wears the reserved
        // folder marker or is spelled exactly like one of the two pseudo-flags, in
        // which case it is REFUSED rather than rendered, because a rendered copy
        // would be indistinguishable from a folder move or a property write. See
        // the type's documentation.
        case .user(let name):
            guard !Self.isReserved(name) else { return nil }
            return name
        }
    }

    func flag(for label: String) -> MailFlag {
        if label == Self.unreadPseudoFlag { return .unread }
        if label == Self.flaggedFlag { return .starred }
        if let name = Self.wellKnownFolder(in: label) {
            // A `folder:` string naming something this build does not know is a
            // user label, not a guess at a system folder.
            return Self.flagsByFolder[name] ?? .user(label)
        }
        // Everything else — a category, or the opaque `parentFolderId` that
        // `GraphMapping.labelIDs` stores — is a user label. Never dropped.
        return .user(label)
    }
}
