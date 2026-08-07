import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// The bug this suite exists for: a live Gmail account synced 500+ messages and the
/// Inbox list showed **nothing**.
///
/// Every layer was individually correct and tested. `IMAPFetchParser` deliberately
/// left `labelIDs` empty because one `FETCH` line does not know its mailbox;
/// `IMAPThreadAssembler` minted ids; `InboxFilter` required a canonical `.inbox`;
/// `UnifiedInbox` merged accounts. Nothing joined them up, so the *seam* — does an
/// IMAP-sourced thread survive the filter the Inbox actually applies — was the one
/// thing no test asked. That is why 1075 passing tests did not see it.
///
/// So these tests are written end-of-chain deliberately: from recorded `FETCH` bytes
/// all the way to what `UnifiedInbox.inbox` returns. A unit test of either half
/// would pass on the broken build.
@Suite("IMAP mail reaches the inbox")
@MainActor struct IMAPInboxVisibilityTests {

    private static let assembler = IMAPThreadAssembler(accountID: IMAPProviderHarness.accountID)

    /// An account whose mailbox directory is persisted, which is what
    /// `LabelVocabularyResolver` needs before it will answer for `.imap` at all.
    private func store(inboxNamed inbox: String = "INBOX") throws -> DocumentMailStore {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: IMAPProviderHarness.accountID, provider: .imap,
                                          address: "a@example.test", displayName: "IMAP",
                                          state: .ready))
        try store.saveIMAPMailboxDirectory(
            IMAPMailboxDirectory([
                // `\Inbox` rather than a bare `flag: .inbox`: `IMAPMailbox` persists
                // only the server's own words and RE-DERIVES the flag on decode, so
                // a directory built with the flag set by hand loses it on the round
                // trip through the store — and a name-only inbox is exactly what
                // this test needs the server to have declared.
                IMAPMailbox(name: inbox, delimiter: "/", attributes: ["\\Inbox"],
                            flag: .inbox, isSpecialUseDeclared: true),
                IMAPMailbox(name: "Archive", delimiter: "/", attributes: ["\\Archive"],
                            flag: .archive, isSpecialUseDeclared: true),
            ]),
            accountID: IMAPProviderHarness.accountID)
        return store
    }

    private func months(for date: Date) -> [String] {
        MonthShard.keys(from: date.addingTimeInterval(-86_400), to: date)
    }

    // MARK: - The bug

    @Test("a thread fetched from INBOX is visible in the unified inbox")
    func fetchedThreadSurvivesTheInboxFilter() throws {
        let store = try store()
        let assembled = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked"))
        // The fixture must actually produce something, or every expectation below
        // is vacuously true — the failure mode this whole file is about.
        #expect(assembled.count == 1)
        for item in assembled { try store.upsertThread(item.thread) }

        let dates = assembled.flatMap { $0.thread.messages.map(\.date) }
        let visible = UnifiedInbox.inbox(store: store, months: months(for: dates.max() ?? Date()))

        #expect(visible.map(\.id) == assembled.map(\.thread.id))
        // The precise reason it used to vanish: no labels at all, so no `.inbox`.
        #expect(visible.allSatisfy { $0.labelIDs.contains("INBOX") })
    }

    @Test("the mailbox name reaches every message, not just the thread")
    func everyMessageCarriesItsMailbox() throws {
        let assembled = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", mailbox: "INBOX"))
        let messages = assembled.flatMap(\.self.thread.messages)
        #expect(!messages.isEmpty)
        #expect(messages.allSatisfy { $0.labelIDs == ["INBOX"] })
    }

    // MARK: - The near-miss the fix had to avoid

    @Test("a message in two mailboxes keeps both, not just the lowest-sorting one")
    func duplicateAcrossMailboxesUnionsItsMailboxes() throws {
        // `assemble` collapses one `Message-ID` onto the lowest-sorting
        // `(mailbox, uid)`, and "Archive" < "INBOX". Taking labels from the
        // surviving locator alone would file genuinely-inboxed mail under Archive
        // only — invisible again, for a new reason.
        let inputs = try IMAPProviderHarness.inputs("imap-provider-fetch-linked",
                                                    mailbox: "INBOX")
            + IMAPProviderHarness.inputs("imap-provider-fetch-linked", mailbox: "Archive")
        let assembled = Self.assembler.assemble(inputs)
        let messages = assembled.flatMap(\.self.thread.messages)
        #expect(!messages.isEmpty)
        #expect(messages.allSatisfy { $0.labelIDs == ["Archive", "INBOX"] })

        let store = try store()
        for item in assembled { try store.upsertThread(item.thread) }
        let dates = messages.map(\.date)
        let visible = UnifiedInbox.inbox(store: store, months: months(for: dates.max() ?? Date()))
        #expect(visible.count == assembled.count)
    }

    // MARK: - The second bug: one vocabulary applied to every backend

    @Test("an IMAP inbox that is not named INBOX is still visible")
    func nonStandardInboxNameIsResolvedThroughTheAccountsVocabulary() throws {
        // Dovecot servers with a namespace prefix really do call it this. Filtering
        // through `defaultLabelVocabulary` — Gmail's — reads it as a user label and
        // drops the thread, which is why `inbox` must resolve per account.
        let store = try store(inboxNamed: "INBOX.Main")
        let assembled = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", mailbox: "INBOX.Main"))
        #expect(assembled.count == 1)
        for item in assembled { try store.upsertThread(item.thread) }

        let dates = assembled.flatMap { $0.thread.messages.map(\.date) }
        let visible = UnifiedInbox.inbox(store: store, months: months(for: dates.max() ?? Date()))
        #expect(visible.map(\.id) == assembled.map(\.thread.id))
    }

    // MARK: - The walk, and the second page that used to undo the first

    @Test("Gmail's All Mail is not walked, so nothing is fetched twice")
    func everythingViewIsExcludedFromTheWalk() {
        let directory = IMAPMailboxDirectory([
            IMAPMailbox(name: "INBOX", delimiter: "/", attributes: ["\\Inbox"],
                        flag: .inbox, isSpecialUseDeclared: true),
            IMAPMailbox(name: "[Gmail]", delimiter: "/", attributes: ["\\Noselect"],
                        flag: .user("[Gmail]"), isSpecialUseDeclared: false),
            IMAPMailbox(name: "[Gmail]/All Mail", delimiter: "/", attributes: ["\\All"],
                        flag: .archive, isSpecialUseDeclared: true),
            IMAPMailbox(name: "Archive", delimiter: "/", attributes: ["\\Archive"],
                        flag: .archive, isSpecialUseDeclared: true),
        ])
        let walked = IMAPProvider.walkable(directory).map(\.name)
        #expect(walked == ["INBOX", "Archive"])
        // A REAL archive folder is still walked. `\All` and `\Archive` share the
        // canonical `.archive` flag, so excluding on the flag would have taken this
        // one too and lost mail that is nowhere else.
        #expect(walked.contains("Archive"))
    }

    @Test("a second mailbox's page does not strip the labels the first one wrote")
    func foldingKeepsAnInboxThreadInTheInbox() throws {
        let store = try store()
        // Page 1: INBOX. Page 2: a Gmail label the same message also carries.
        // Separate `assemble` calls, same thread id — which is exactly how the
        // walk pages, and how a blind `upsertThread` used to lose the INBOX label.
        let first = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", mailbox: "INBOX"))
        let second = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", mailbox: "Work"))
        #expect(first.count == 1)
        #expect(first.map(\.thread.id) == second.map(\.thread.id))

        try IMAPThreadAssembler.commit(first, to: store)
        try IMAPThreadAssembler.commit(second, to: store)

        let thread = try #require(store.thread(first[0].thread.id))
        #expect(thread.messages.allSatisfy { $0.labelIDs == ["INBOX", "Work"] })
        // One message, not two: the same mail in two mailboxes has two locators,
        // and storing both would show the user one message twice.
        #expect(thread.messages.count == first[0].thread.messages.count)

        let dates = thread.messages.map(\.date)
        let visible = UnifiedInbox.inbox(store: store, months: months(for: dates.max() ?? Date()))
        #expect(visible.map(\.id) == [first[0].thread.id])
    }

    @Test("a message the current page did not fetch is not deleted from its thread")
    func foldingCarriesOverMessagesTheFetchDidNotMention() throws {
        let store = try store()
        let assembled = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", mailbox: "INBOX"))
        try IMAPThreadAssembler.commit(assembled, to: store)
        let before = try #require(store.thread(assembled[0].thread.id)).messages.count

        // A later page returns only ONE of the thread's messages, which is normal:
        // a page covers a mailbox, never the whole account. Replacing the document
        // with it would delete the rest on every sync.
        let partial = IMAPThreadAssembler.Assembled(
            thread: MailThread(id: assembled[0].thread.id,
                               accountID: assembled[0].thread.accountID,
                               messages: [assembled[0].thread.messages[0]]),
            candidateLosingIDs: [])
        try IMAPThreadAssembler.commit([partial], to: store)

        #expect(try #require(store.thread(assembled[0].thread.id)).messages.count == before)
    }

    @Test("folding takes the server's current read state, not the stored one")
    func foldingDoesNotResurrectStaleFlags() throws {
        let store = try store()
        let assembled = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", mailbox: "INBOX"))
        var unread = assembled[0].thread
        unread.messages = unread.messages.map { message in
            var message = message; message.isRead = false; return message
        }
        try IMAPThreadAssembler.commit(
            [.init(thread: unread, candidateLosingIDs: [])], to: store)

        // The next fetch says read. Only labels are unioned; everything else is the
        // server's current answer, or clearing unread would never stick.
        var read = assembled[0].thread
        read.messages = read.messages.map { message in
            var message = message; message.isRead = true; return message
        }
        try IMAPThreadAssembler.commit(
            [.init(thread: read, candidateLosingIDs: [])], to: store)

        #expect(try #require(store.thread(read.id)).messages.allSatisfy(\.isRead))
    }

    @Test("an IMAP account with no persisted directory contributes nothing rather than guessing")
    func unresolvableAccountIsRefusedNotFallenBackOn() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: IMAPProviderHarness.accountID, provider: .imap,
                                          address: "a@example.test", displayName: "IMAP",
                                          state: .ready))
        // No `saveIMAPMailboxDirectory` — the resolver refuses, and a refusal must
        // not silently become Gmail's vocabulary.
        let assembled = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked"))
        for item in assembled { try store.upsertThread(item.thread) }
        let dates = assembled.flatMap { $0.thread.messages.map(\.date) }
        #expect(UnifiedInbox.inbox(store: store, months: months(for: dates.max() ?? Date())).isEmpty)
        // …while the unfiltered read still sees them, which is what makes the line
        // above a statement about the FILTER and not about the store being empty.
        #expect(!UnifiedInbox.summaries(store: store,
                                        months: months(for: dates.max() ?? Date())).isEmpty)
    }
}
