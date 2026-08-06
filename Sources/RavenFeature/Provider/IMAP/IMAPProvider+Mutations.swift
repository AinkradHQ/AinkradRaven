import Foundation

/// `IMAPProvider`'s write path, its on-demand body/attachment fetches, and search.
///
/// Split from `IMAPProvider.swift` for the repo's line limit, along the same seam
/// `IMAPDeltaStrategy`/`+Readers` and `IMAPAuthTests`/`IMAPAuthChannelTests` were
/// split: everything here issues a command *about one message or one thread* the
/// caller named, whereas the other file walks mailboxes and decides what changed.
extension IMAPProvider {

    // MARK: - Bodies and attachments

    /// Fetches the body of one message, on demand, in two commands.
    ///
    /// Two rather than one because the part numbers of the text parts are not
    /// knowable until the `BODYSTRUCTURE` has been read, and asking for
    /// `BODY.PEEK[1]`/`BODY.PEEK[2]` blind would download a random part — very
    /// often an attachment — and put its bytes in `plainText`.
    ///
    /// `BODY.PEEK`, never `BODY`: reading a message from a thread view must not set
    /// `\Seen` behind the user's back. That is the same reason Task 12's arrival
    /// fetch peeks.
    func fetchBody(messageID: String) async throws -> MessageBody {
      try await withSession { working in
        let locator = try await locate(messageID, on: working)
        let structure = try await fetchOne(locator, items: [.atom("BODYSTRUCTURE")],
                                          on: working.session)
        var sections: [IMAPCommand.Argument] = [.atom("BODYSTRUCTURE")]
        if let tree = structure.bodyStructure {
            if tree.children.isEmpty {
                // A single-part message's only part is not addressable as `1` on
                // every server, and `BODY[TEXT]` is what `IMAPFetchParser.body`
                // reads for it — see its `allowsWholeBodyFallback`.
                sections.append(.atom("BODY.PEEK[TEXT]"))
            } else {
                for part in [tree.plainTextPart, tree.htmlPart, tree.calendarPart] {
                    guard let number = part?.partNumber else { continue }
                    sections.append(.atom("BODY.PEEK[\(number)]"))
                }
            }
        }
        let full = try await fetchOne(locator, items: sections, on: working.session)
        return IMAPFetchParser.body(full, messageID: messageID)
      }
    }

    /// One part's raw bytes.
    ///
    /// **Nothing is written to disk, and nothing is cached in memory either.** The
    /// only reference to the bytes is the `Data` returned to the caller, matching
    /// `MailProvider.fetchAttachment`'s contract and `GmailProvider`'s behaviour:
    /// two calls for the same part issue two `UID FETCH`es, which
    /// `IMAPProviderTests` asserts on recorded bytes rather than trusting this
    /// comment. A disk cache would leave the user's attachments readable after
    /// sign-out, which `DocumentMailStore.purge` exists to prevent and could not
    /// reach.
    func fetchAttachment(messageID: String, attachmentID: String) async throws -> Data {
      try await withSession { working in
        let locator = try await locate(messageID, on: working)
        let response = try await fetchOne(
            locator,
            items: [.atom("BODYSTRUCTURE"), .atom("BODY.PEEK[\(attachmentID)]")],
            on: working.session)
        guard let payload = response.sections[attachmentID.uppercased()]
            ?? response.sections[attachmentID] else {
            throw MailError.decodingFailed("attachment \(attachmentID)")
        }
        // Decoded with the part's OWN `Content-Transfer-Encoding`, read from the
        // structure that came back on the same command. Assuming base64 would
        // corrupt a `7bit`/`binary` part, and assuming none would hand the UI
        // base64 text as if it were a PDF.
        let encoding = response.bodyStructure?.preOrder
            .first { $0.partNumber == attachmentID }?.encoding
        return RFC822Message.decodeTransferEncoding(payload, encoding: encoding)
      }
    }

    /// `SELECT`s the message's mailbox and returns where it is, refusing a locator
    /// this build did not mint or whose `UIDVALIDITY` generation the server has moved
    /// past.
    ///
    /// Takes the session rather than acquiring one, so it cannot become a second
    /// unreleased acquire: `withSession` above owns the lease for the whole operation.
    private func locate(_ messageID: String,
                        on working: IMAPWorkingSession) async throws -> IMAPMessageLocator {
        guard let locator = IMAPMessageLocator(encoded: messageID) else {
            throw MailError.decodingFailed("message id \(messageID)")
        }
        let selection = try await select(locator.mailbox, on: working.session)
        guard selection.uidValidity == locator.uidValidity else {
            await index.forget(mailbox: locator.mailbox)
            throw MailError.unknownThread(messageID)
        }
        return locator
    }

    private func fetchOne(_ locator: IMAPMessageLocator,
                          items: [IMAPCommand.Argument],
                          on session: IMAPSession) async throws -> IMAPFetchResponse {
        let response = try await session.execute(IMAPCommand(
            "UID FETCH", [.atom(String(locator.uid)), .list(items)], isExclusive: true))
        guard let fetched = try IMAPDeltaStrategy.fetches(in: response.untagged).first else {
            throw MailError.unknownThread(locator.encoded)
        }
        return fetched
    }

    // MARK: - applyLabels

    /// Applies a rendered `LabelMutation`.
    ///
    /// The mutation arrives in `IMAPVocabulary`'s strings, which are two different
    /// kinds of thing, and the split is made here on the string itself
    /// (`IMAPVocabulary.isSystemFlag`, i.e. a leading backslash — what RFC 3501
    /// reserves for flags and forbids in mailbox names):
    ///
    /// - **Flags** become `UID STORE +FLAGS`/`-FLAGS`, with `\Unseen` inverted onto
    ///   `\Seen`. See `IMAPVocabulary` for why the pseudo-flag exists.
    /// - **Mailbox names** become a *move*, because on a folder-based backend
    ///   "gaining a folder" and "losing a folder" are the same single act.
    ///
    /// ## How a destination is chosen, and when it refuses
    ///
    /// `ThreadAction` is written in canonical flags shaped by Gmail's model:
    /// archive is `remove: [.inbox]` with nothing added, and trash is
    /// `add: [.trash], remove: [.inbox]`. So:
    ///
    /// - An **added** mailbox name is the destination (trash, spam, a user folder).
    /// - Otherwise a **removed** mailbox name means "move out of here", and the only
    ///   place a folder-based backend can move mail to without deleting it is the
    ///   archive mailbox.
    /// - If a move is called for and no destination resolves — an account whose
    ///   server has no archive folder — this **throws**. It does not fall back to
    ///   flags-only, because a silent no-op after the UI has already applied the
    ///   change locally leaves the two permanently disagreeing, with the user
    ///   believing the mail was filed.
    ///
    /// Flags are stored BEFORE the move: `UID MOVE` invalidates the source UIDs, so
    /// the other order would `STORE` against UIDs that no longer exist.
    func applyLabels(_ mutation: LabelMutation) async throws {
        let addFlags = mutation.add.filter(IMAPVocabulary.isSystemFlag)
        let removeFlags = mutation.remove.filter(IMAPVocabulary.isSystemFlag)
        let addedMailboxes = mutation.add.filter { !IMAPVocabulary.isSystemFlag($0) }
        let removedMailboxes = mutation.remove.filter { !IMAPVocabulary.isSystemFlag($0) }
        guard !addFlags.isEmpty || !removeFlags.isEmpty
                || !addedMailboxes.isEmpty || !removedMailboxes.isEmpty else { return }

        try await withSession { working in
        var byMailbox: [String: [UInt32]] = [:]
        for threadID in mutation.threadIDs {
            for locator in await index.locators(threadID: threadID) {
                byMailbox[locator.mailbox, default: []].append(locator.uid)
            }
        }
        guard !byMailbox.isEmpty else { return }

        let capabilities = try await working.session.capabilities()
        for (mailbox, uids) in byMailbox.sorted(by: { $0.key < $1.key }) {
            let set = uids.sorted().map(String.init).joined(separator: ",")
            try await select(mailbox, on: working.session)
            try await store(flags: addFlags, removing: removeFlags, uids: set,
                            on: working.session)
            guard let destination = try destination(
                added: addedMailboxes, removed: removedMailboxes,
                source: mailbox, directory: working.directory) else { continue }
            try await move(uids: set, to: destination, hasMove: capabilities.contains("MOVE"),
                           on: working.session)
        }
        }
    }

    /// `UID STORE` for the flag half, at most one command per sign.
    ///
    /// `\Unseen` is translated here and only here: adding it is `-FLAGS (\Seen)` and
    /// removing it is `+FLAGS (\Seen)`. `.silent` is used because the response's
    /// untagged `FETCH` data is not read — the local store was already updated
    /// optimistically by `ThreadMutationApplier` — and suppressing it keeps a
    /// mark-all-read over a thousand messages from returning a thousand lines.
    private func store(flags added: [String], removing removed: [String],
                       uids: String, on session: IMAPSession) async throws {
        var plus = added.filter { $0 != IMAPVocabulary.unseenPseudoFlag }
        var minus = removed.filter { $0 != IMAPVocabulary.unseenPseudoFlag }
        if added.contains(IMAPVocabulary.unseenPseudoFlag) { minus.append("\\Seen") }
        if removed.contains(IMAPVocabulary.unseenPseudoFlag) { plus.append("\\Seen") }
        for (operation, flags) in [("+FLAGS.SILENT", plus), ("-FLAGS.SILENT", minus)]
        where !flags.isEmpty {
            try await session.execute(IMAPCommand(
                "UID STORE",
                [.atom(uids), .atom(operation), .list(flags.sorted().map { .atom($0) })],
                isExclusive: true))
        }
    }

    /// The mailbox a move should land in, or `nil` when no move was asked for.
    private func destination(added: [String], removed: [String], source: String,
                             directory: IMAPMailboxDirectory) throws -> String? {
        if let target = added.first(where: { $0 != source }) { return target }
        guard !added.isEmpty || !removed.isEmpty else { return nil }
        guard !removed.isEmpty else { return nil }
        guard removed.contains(source) else { return nil }
        guard let archive = directory.mailbox(for: .archive)?.name else {
            throw MailError.providerFailed(
                status: -1, message: "no archive mailbox for this account")
        }
        return archive == source ? nil : archive
    }

    /// `UID MOVE` when advertised, otherwise RFC 3501's three-command equivalent.
    ///
    /// The fallback's order is not interchangeable: `COPY` first, so a failure
    /// leaves the message where it was; then `\Deleted`; then `EXPUNGE`. Marking or
    /// expunging before the copy succeeded is how a move loses mail, and RFC 6851
    /// exists precisely because those three steps are not atomic.
    private func move(uids: String, to destination: String, hasMove: Bool,
                      on session: IMAPSession) async throws {
        if hasMove {
            try await session.execute(IMAPCommand(
                "UID MOVE", [.atom(uids), .text(destination)], isExclusive: true))
            return
        }
        try await session.execute(IMAPCommand(
            "UID COPY", [.atom(uids), .text(destination)], isExclusive: true))
        try await session.execute(IMAPCommand(
            "UID STORE", [.atom(uids), .atom("+FLAGS.SILENT"), .list([.atom("\\Deleted")])],
            isExclusive: true))
        try await session.execute(IMAPCommand("EXPUNGE", isExclusive: true))
    }

    // MARK: - Search

    /// Full-archive search via `UID SEARCH`.
    ///
    /// **The query is not translated, and that is the protocol's documented stance**
    /// (`MailProvider.searchThreads`): Gmail's `q` grammar — `from:`, `label:`,
    /// `is:unread` — is close to but not the same as `ThreadSearch.parse`'s, and no
    /// attempt is made to reconcile either with IMAP's `SEARCH` keys. The
    /// consequence, stated plainly because a caller will hit it: a query like
    /// `from:a@example.test` is sent as `SEARCH TEXT "from:a@example.test"` and
    /// matches messages whose text literally contains that string, not messages
    /// from that sender. IMAP search keys are structural atoms (`FROM`, `SUBJECT`,
    /// `UNSEEN`), so translating would mean writing a third grammar and picking
    /// which of the other two it is bug-compatible with — the exact "reconcile the
    /// grammars" work the protocol declines.
    ///
    /// One mailbox is searched, since `SEARCH` is scoped to the selected mailbox:
    /// the archive/all-mail folder when the account has one (it holds everything),
    /// otherwise the inbox.
    func searchThreads(query: String, limit: Int) async throws -> [MailThread] {
        guard limit > 0, !query.isEmpty else { return [] }
        return try await withSession { working in
        let mailbox = working.directory.mailbox(for: .archive)
            ?? working.directory.mailbox(for: .inbox)
        guard let mailbox else { return [] }
        let selection = try await select(mailbox.name, on: working.session)
        let uids = try await searchUIDs([.atom("TEXT"), .text(query)], on: working.session)
        guard !uids.isEmpty else { return [] }
        let inputs = try await fetchMessages(uids: Array(uids.prefix(limit)),
                                            mailbox: mailbox.name,
                                            uidValidity: selection.uidValidity,
                                            on: working.session)
        return await commit(inputs)
        }
    }

    // MARK: - Sending

    /// IMAP does not transmit mail; SMTP submission is Task 15.
    ///
    /// A throw rather than `capabilities = .readOnly`, because read-only is a claim
    /// about the *account* that `MailProviderRouter` uses to refuse `applyLabels`
    /// too — and `applyLabels` works here. Naming the missing half is the honest
    /// shape: the flag path is usable today and the send path is not yet wired.
    func send(_ message: OutgoingMessage) async throws -> String {
        throw MailError.providerFailed(
            status: -1, message: "IMAP accounts transmit over SMTP, which is not wired yet")
    }
}
