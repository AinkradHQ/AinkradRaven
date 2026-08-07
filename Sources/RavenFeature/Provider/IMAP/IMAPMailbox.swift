import Foundation

/// One mailbox as a `LIST` (or `LSUB`) response described it.
///
/// The `attributes` are kept **verbatim and unfiltered** alongside the resolved
/// `flag`. Two reasons: `\Noselect`/`\HasChildren` are needed by the walker and
/// are not flags, and keeping the server's own words means a future special-use
/// attribute this build has never heard of is still visible to a diagnostic
/// rather than erased at parse time.
///
/// ## Codable, and what is deliberately NOT stored
///
/// Task 16 persists the account's mailbox list so the static
/// `LabelVocabularyResolver` can answer without a live session. Only what the
/// **server said** is written — `name`, `delimiter`, `attributes` — and `flag`/
/// `isSpecialUseDeclared` are recomputed on decode through the same
/// `IMAPMailboxList.resolve` a live `LIST` goes through. Storing the resolved flag
/// instead would freeze one build's heuristics into the document: a later fix to
/// `nameHeuristics` (of the exact kind this file has already needed once) would
/// apply to freshly-listed accounts and not to stored ones, and the two would
/// disagree about which folder is the trash.
public struct IMAPMailbox: Equatable, Sendable, Codable {
    /// The mailbox name exactly as the server spelled it, including any
    /// hierarchy. This is what `SELECT`/`UID COPY` must be given, so it is never
    /// normalised, case-folded or split.
    public let name: String

    /// The hierarchy delimiter, or `nil` for a flat namespace (`LIST` sends
    /// `NIL`). `nil` and `""` are different things and neither is guessed.
    public let delimiter: String?

    /// The `LIST` attributes, verbatim, in arrival order.
    public let attributes: [String]

    /// The canonical meaning of this mailbox.
    ///
    /// Never `nil` and the mailbox is never dropped: a folder that matches no
    /// special use is `.user(name)`, because a mailbox the domain does not
    /// understand is still a mailbox the user can see and the provider must
    /// keep. Dropping it would silently hide mail.
    public let flag: MailFlag

    /// Whether the mailbox can hold messages. `\Noselect` containers (a bare
    /// `[Gmail]` node, say) are listed and kept — they are part of the hierarchy
    /// — but must never be `SELECT`ed.
    public var isSelectable: Bool { !attributes.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame } }

    /// Whether this is RFC 6154's `\All` — a *view* of every message in the
    /// account rather than a place messages live. Gmail's "All Mail" is the one
    /// everyone meets.
    ///
    /// Tested on the server's own attribute, NOT on `flag == .archive`, and the
    /// difference is the whole point: `\All` and `\Archive` both resolve to the
    /// canonical `.archive`, but a real archive folder holds mail that is nowhere
    /// else while `\All` holds a second copy of everything. Keying on the flag
    /// would exclude the wrong one and lose genuinely archived mail.
    ///
    /// `IMAPProvider.walkable` is the only reader; see it for why a sync skips
    /// this mailbox and what that deliberately costs.
    public var isEverythingView: Bool {
        attributes.contains { $0.caseInsensitiveCompare("\\All") == .orderedSame }
    }

    /// Whether the canonical meaning came from a `SPECIAL-USE` attribute rather
    /// than from a name heuristic. Recorded because the two have very different
    /// confidence and a mis-heuristic that moves mail into the wrong folder is
    /// the failure this whole file exists to avoid.
    public let isSpecialUseDeclared: Bool

    init(name: String, delimiter: String?, attributes: [String], flag: MailFlag,
         isSpecialUseDeclared: Bool) {
        self.name = name
        self.delimiter = delimiter
        self.attributes = attributes
        self.flag = flag
        self.isSpecialUseDeclared = isSpecialUseDeclared
    }

    /// Only the server's own words are keys; see this type's documentation for why
    /// `flag` is not among them.
    private enum CodingKeys: String, CodingKey { case name, delimiter, attributes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let delimiter = try container.decodeIfPresent(String.self, forKey: .delimiter)
        let attributes = try container.decodeIfPresent([String].self, forKey: .attributes) ?? []
        let resolved = IMAPMailboxList.resolve(name: name, attributes: attributes,
                                               delimiter: delimiter)
        self.init(name: name, delimiter: delimiter, attributes: attributes,
                  flag: resolved.flag, isSpecialUseDeclared: resolved.declared)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(delimiter, forKey: .delimiter)
        try container.encode(attributes, forKey: .attributes)
    }
}

/// Reading `LIST`/`LSUB` responses, and mapping mailboxes to canonical flags.
///
/// Parsing goes through `IMAPValueReader` — the token-tree reader Task 10 landed
/// — rather than over bytes. That is not merely reuse: it is what makes a mailbox
/// name sent as a `{n}` literal work, since the lexer has already carved the
/// literal's bytes out opaquely and nothing here can mistake a `/` or a CRLF
/// inside a name for structure.
enum IMAPMailboxList {

    /// Attribute → canonical flag, for RFC 6154 `SPECIAL-USE` plus the `\Inbox`
    /// attribute some servers send for the root mailbox.
    ///
    /// Keys are lowercased because IMAP flags are case-insensitive; a server
    /// sending `\sent` means the same thing as `\Sent` and a case-sensitive
    /// table would quietly demote it to a user label.
    private static let specialUse: [String: MailFlag] = [
        "\\inbox": .inbox,
        "\\sent": .sent,
        "\\trash": .trash,
        "\\drafts": .draft,
        "\\archive": .archive,
        // Gmail's IMAP spells "All Mail" `\All`, and "everything, filed out of
        // the inbox" is exactly what `.archive` means here.
        "\\all": .archive,
        "\\junk": .spam,
    ]

    /// Mailbox name (lowercased) → canonical flag, for servers with no
    /// `SPECIAL-USE` extension.
    ///
    /// Matched against the whole name, or against the last component of a name
    /// that is **exactly `INBOX<delimiter><component>`** — and nowhere else.
    /// Both halves of that rule are deliberate:
    ///
    /// - A general last-component heuristic reads `Folder A/Trash` — a user's own
    ///   subfolder — as *the* trash, and the consequence is a delete path aimed
    ///   at real mail. So it is not general.
    /// - Whole-name-only was too narrow to be safe either, and the earlier
    ///   comment here justified it with something false. Courier, and Dovecot in
    ///   its maildir++ layout, put every special folder under the INBOX
    ///   namespace (`INBOX.Trash`, `INBOX.Sent`) and need not advertise
    ///   `SPECIAL-USE` at all. On whole-name matching alone such an account has
    ///   *no* trash, sent, drafts or archive, so `mailbox(for:)` returns nil for
    ///   every folder mutation. Refusing beats mutating the wrong folder, but it
    ///   is still a whole server class with no working archive.
    ///
    /// The INBOX-rooted form covers that layout without reopening the hazard,
    /// because `Folder A/Trash` is not INBOX-rooted and `INBOX.Folder A.Trash`
    /// is more than one component deep — a user subfolder in both cases.
    private static let nameHeuristics: [String: MailFlag] = [
        "sent": .sent, "sent items": .sent, "sent mail": .sent, "sent messages": .sent,
        "trash": .trash, "deleted": .trash, "deleted items": .trash,
        "deleted messages": .trash, "bin": .trash,
        "drafts": .draft, "draft": .draft,
        "archive": .archive, "archives": .archive, "all mail": .archive,
        "junk": .spam, "junk e-mail": .spam, "junk email": .spam,
        "spam": .spam, "bulk mail": .spam,
    ]

    /// `true` when this is a `LIST`/`LSUB`/`XLIST` line at all.
    static func isMailboxListing(_ response: IMAPUntaggedResponse) -> Bool {
        guard let keyword = response.keyword else { return false }
        return keyword == "LIST" || keyword == "LSUB" || keyword == "XLIST"
    }

    /// Parses one untagged response, or returns `nil` when it is not a mailbox
    /// listing. `nil` rather than an error so a caller can hand it every
    /// untagged line of a command's response — `LIST` is routinely interleaved
    /// with `OK`/`FLAGS` lines.
    static func parse(_ response: IMAPUntaggedResponse) throws -> IMAPMailbox? {
        guard isMailboxListing(response) else { return nil }
        var reader = IMAPValueReader(response.tokens, from: 1)

        guard let attributeList = try reader.readValue().listValue else {
            throw IMAPFetchParseError.unexpectedToken("LIST attributes are not a list")
        }
        let attributes = attributeList.compactMap(\.stringValue)

        let delimiterValue = try reader.readValue()
        // `NIL` is a flat namespace. A *quoted* `"NIL"` would be an actual
        // one-character-per-nothing delimiter and is kept as text — the same
        // distinction `IMAPToken` draws, held one layer up.
        let delimiter = delimiterValue.isNil ? nil : delimiterValue.stringValue

        let nameValue = try reader.readValue()
        guard let name = nameValue.stringValue, !name.isEmpty else {
            throw IMAPFetchParseError.unexpectedToken("LIST mailbox name is missing")
        }

        let resolved = resolve(name: name, attributes: attributes, delimiter: delimiter)
        return IMAPMailbox(name: name, delimiter: delimiter, attributes: attributes,
                           flag: resolved.flag, isSpecialUseDeclared: resolved.declared)
    }

    /// The canonical meaning of a mailbox, attributes first.
    ///
    /// Attributes beat the name unconditionally. A server that labels a mailbox
    /// `\Trash` while calling it `Folder A` means it: honouring the name instead
    /// would leave the account with no trash folder and a "Folder A" the user
    /// deletes into by accident.
    static func resolve(name: String, attributes: [String],
                        delimiter: String?) -> (flag: MailFlag, declared: Bool) {
        for attribute in attributes {
            if let flag = specialUse[attribute.lowercased()] {
                return (flag, true)
            }
        }
        // `INBOX` is case-insensitively reserved by RFC 3501 and is the one name
        // that is canonical whether or not the server says so.
        if name.caseInsensitiveCompare("INBOX") == .orderedSame {
            return (.inbox, false)
        }
        if let flag = nameHeuristics[name.lowercased()] {
            return (flag, false)
        }
        if let component = inboxRootedComponent(of: name, delimiter: delimiter),
           let flag = nameHeuristics[component.lowercased()] {
            return (flag, false)
        }
        return (.user(name), false)
    }

    /// The single component of a name of the form `INBOX<delimiter><component>`,
    /// or `nil` for anything else.
    ///
    /// "Single" is enforced, not incidental: `INBOX.Folder A.Trash` is a user's
    /// subfolder of a subfolder and must come back `nil`, exactly as
    /// `Folder A/Trash` does. Without the depth check this would be a
    /// last-component heuristic wearing an INBOX prefix.
    private static func inboxRootedComponent(of name: String, delimiter: String?) -> String? {
        guard let delimiter, !delimiter.isEmpty else { return nil }
        let prefix = "INBOX" + delimiter
        guard name.count > prefix.count,
              name.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
        else { return nil }
        let remainder = String(name.dropFirst(prefix.count))
        guard !remainder.isEmpty, !remainder.contains(delimiter) else { return nil }
        return remainder
    }
}

/// The account's mailbox set, with the flag → mailbox direction a mutation needs.
///
/// Separate from the parser because the reverse direction is a property of the
/// *set*, not of any one line: "which mailbox is the trash" is only answerable
/// once every `LIST` line has been read.
///
/// `Codable` since Task 16, which persists it per account
/// (`DocumentKeys.imapMailboxes`) so `LabelVocabularyResolver` can build an
/// `IMAPVocabulary` without a live `LIST`. `refusedLineCount` is not persisted:
/// it describes one `LIST` response's parse, not the account, and a decoded
/// directory has no refused lines of its own.
public struct IMAPMailboxDirectory: Equatable, Sendable, Codable {
    public let mailboxes: [IMAPMailbox]

    /// How many `LIST` lines this build could not parse.
    ///
    /// Counted and exposed rather than swallowed. The directory keeps the
    /// mailboxes it understood — one malformed line must not leave the account
    /// with zero mailboxes and no way even to locate INBOX, which is the same
    /// one-bad-row-strands-everything shape `ProviderKind`, `MailAccount.State`
    /// and this file's own cursor sibling all exist to avoid. But a silently
    /// shorter mailbox list is its own hazard — an archive that has quietly gone
    /// missing looks identical to a server that has none — so the count is part
    /// of the value and a caller can surface or log it.
    public let refusedLineCount: Int

    private enum CodingKeys: String, CodingKey { case mailboxes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([IMAPMailbox].self, forKey: .mailboxes))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mailboxes, forKey: .mailboxes)
    }

    init(_ mailboxes: [IMAPMailbox], refusedLineCount: Int = 0) {
        self.mailboxes = mailboxes
        self.refusedLineCount = refusedLineCount
    }

    /// Parses a whole command's untagged lines: non-listings are skipped, and a
    /// listing this parser refuses costs that one line.
    init(untagged responses: [IMAPUntaggedResponse]) {
        var parsed: [IMAPMailbox] = []
        var refused = 0
        for response in responses {
            do {
                if let mailbox = try IMAPMailboxList.parse(response) { parsed.append(mailbox) }
            } catch {
                refused += 1
            }
        }
        self.init(parsed, refusedLineCount: refused)
    }

    /// The mailbox carrying `flag`, or `nil` when the account has none.
    ///
    /// `nil` is a real answer and callers must not invent a name from it: a
    /// server with no archive folder needs the mutation refused, not a `SELECT`
    /// of a guessed `"Archive"` that does not exist. A declared `SPECIAL-USE`
    /// match wins over a heuristic one when both exist.
    public func mailbox(for flag: MailFlag) -> IMAPMailbox? {
        let matches = mailboxes.filter { $0.flag == flag && $0.isSelectable }
        return matches.first(where: \.isSpecialUseDeclared) ?? matches.first
    }

    /// The canonical meaning of a mailbox name this directory knows. An unknown
    /// name reads as `.user(name)` rather than nothing — the same
    /// never-drop-a-label rule `LabelVocabulary.flag(for:)` states.
    public func flag(for name: String) -> MailFlag {
        mailboxes.first { $0.name == name }?.flag ?? .user(name)
    }
}
