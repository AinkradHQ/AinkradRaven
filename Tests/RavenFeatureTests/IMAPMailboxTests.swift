import Testing
import Foundation
@testable import RavenFeature

@Suite("IMAP LIST parsing and mailbox↔flag mapping")
struct IMAPMailboxTests {

    /// The recorded `LIST` capture, lexed through the same path `IMAPSession`
    /// uses. Fixtures are CRLF-exact and the tree is `-text` in `.gitattributes`.
    private func directory(_ fixture: String = "imap-list-mailboxes") throws -> IMAPMailboxDirectory {
        IMAPMailboxDirectory(untagged: try IMAPFetchWire.untaggedResponses(
            try IMAPFetchWire.fixture(fixture)))
    }

    private func mailbox(_ name: String) throws -> IMAPMailbox {
        try #require(try directory().mailboxes.first { $0.name == name },
                     "no mailbox named \(name) in the capture")
    }

    private func parsedLine(_ wire: String) throws -> IMAPMailbox {
        let responses = try IMAPFetchWire.untaggedResponses(Data(wire.utf8))
        let response = try #require(responses.first)
        return try #require(try IMAPMailboxList.parse(response))
    }

    // MARK: - Shape

    @Test("every LIST line in the capture becomes a mailbox, and nothing else does")
    func capturedMailboxes() throws {
        // Whole-collection compare, in wire order: the `* OK` line is skipped and
        // no mailbox is dropped. Order also pins that the literal-named mailbox
        // did not swallow the line after it.
        #expect(try directory().mailboxes.map(\.name) == [
            "INBOX", "Folder A", "Folder A/Trash", "Trash", "Sent Items", "Folder B",
            "Folder C", "NIL", "Folder A (x)", "Drafts", "Folder E",
        ])
    }

    @Test("one refused LIST line costs that line only, and is counted")
    func refusedLineDoesNotStrandTheDirectory() throws {
        // The capture is good line / refused line / good line. A directory that
        // propagated the throw would hand the account ZERO mailboxes — it could
        // not even locate INBOX — because one folder the parser dislikes.
        let directory = try directory("imap-list-refused-line")
        #expect(directory.mailboxes.map(\.name) == ["Folder A", "Folder B"])
        #expect(directory.mailboxes.map(\.flag) == [.trash, .user("Folder B")])
        // Observable, not swallowed: a quietly shorter mailbox list is
        // indistinguishable from a server that genuinely has fewer folders.
        #expect(directory.refusedLineCount == 1)
        // The `* OK` line is not a refusal — it was never a listing.
        #expect(try self.directory().refusedLineCount == 0)
    }

    @Test("LSUB and XLIST are mailbox listings too")
    func lsubAndXListAreListings() throws {
        // `LSUB` appears in the INBOX-namespace capture, so the subscribed-list
        // path is exercised by a recorded response, not only inline.
        #expect(try directory("imap-list-inbox-namespace").mailboxes.map(\.name)
                .contains("INBOX.Junk"))
        #expect(try parsedLine("* LSUB (\\HasNoChildren) \"/\" \"Folder B\"\r\n").name
                == "Folder B")
        #expect(try parsedLine("* XLIST (\\HasNoChildren \\Trash) \"/\" \"Folder B\"\r\n").flag
                == .trash)
        for wire in ["* LSUB (\\HasNoChildren) \"/\" \"Folder B\"\r\n",
                     "* XLIST (\\HasNoChildren) \"/\" \"Folder B\"\r\n"] {
            let response = try #require(try IMAPFetchWire.untaggedResponses(Data(wire.utf8)).first)
            #expect(IMAPMailboxList.isMailboxListing(response))
        }
    }

    @Test("a non-LIST untagged line is not a mailbox")
    func nonListLineIsNil() throws {
        let responses = try IMAPFetchWire.untaggedResponses(
            Data("* OK [UIDVALIDITY 111] Ok\r\n".utf8))
        let response = try #require(responses.first)
        #expect(IMAPMailboxList.isMailboxListing(response) == false)
        #expect(try IMAPMailboxList.parse(response) == nil)
    }

    @Test("a mailbox name sent as a literal keeps its parentheses and spaces")
    func literalNameIsOpaque() throws {
        // The name is `{12}Folder A (x)`. A parser that re-lexed the literal's
        // bytes would read the `(`/`)` as structure and hand back a
        // plausible-but-wrong `Folder A` — a *wrong* mailbox name, which is the
        // shape of misparse that actually ships.
        let box = try mailbox("Folder A (x)")
        #expect(box.name == "Folder A (x)")
        #expect(box.flag == .archive)
        #expect(box.isSpecialUseDeclared)
        #expect(box.attributes == ["\\HasNoChildren", "\\Archive"])
    }

    @Test("a NIL delimiter and a quoted \"NIL\" delimiter are different things")
    func nilDelimiterIsNotTheTextNIL() throws {
        #expect(try mailbox("INBOX").delimiter == nil)
        let quoted = try mailbox("NIL")
        #expect(quoted.delimiter == "NIL")
        #expect(quoted.name == "NIL")
        #expect(quoted.flag == .user("NIL"))
    }

    // MARK: - SPECIAL-USE

    @Test("SPECIAL-USE attributes map to canonical flags")
    func specialUseAttributes() throws {
        #expect(try mailbox("Folder A").flag == .trash)
        #expect(try mailbox("Folder A (x)").flag == .archive)
        #expect(try mailbox("Folder E").flag == .spam)
        #expect(try parsedLine("* LIST (\\HasNoChildren \\Drafts) \"/\" \"Folder F\"\r\n").flag
                == .draft)
        #expect(try parsedLine("* LIST (\\Inbox) \"/\" \"Folder G\"\r\n").flag == .inbox)
        // Gmail spells "All Mail" `\All`, and "everything, filed out of the
        // inbox" is what `.archive` means here.
        #expect(try parsedLine("* LIST (\\All) \"/\" \"Folder H\"\r\n").flag == .archive)
    }

    @Test("a SPECIAL-USE attribute beats the mailbox's name")
    func attributeBeatsName() throws {
        // `(\Trash) "Folder A"`: a parser that ignored attributes and ran the
        // name heuristic would answer `.user("Folder A")` — plausible, and it
        // would leave the account with no trash folder at all.
        let box = try mailbox("Folder A")
        #expect(box.flag == .trash)
        #expect(box.isSpecialUseDeclared)

        // `(\Archive) "Trash"` is the case that makes this a *precedence* test
        // rather than a coincidence: name and attribute disagree. A parser that
        // consulted the heuristic first answers `.trash` — plausible, wrong,
        // and it points the delete path at the user's archive.
        let disagreeing = try mailbox("Trash")
        #expect(disagreeing.flag == .archive)
        #expect(disagreeing.isSpecialUseDeclared)
    }

    @Test("attribute matching is case-insensitive, as IMAP flags are")
    func attributeCaseInsensitive() throws {
        // The capture sends `\sent` lower-case. A case-sensitive table demotes
        // it to `.user("Folder B")` — again plausible, and again it silently
        // loses the Sent folder.
        let box = try mailbox("Folder B")
        #expect(box.attributes == ["\\HasNoChildren", "\\sent"])
        #expect(box.flag == .sent)
        #expect(box.isSpecialUseDeclared)
    }

    // MARK: - Name heuristics

    @Test("with no SPECIAL-USE attribute the mailbox name is the heuristic")
    func nameHeuristics() throws {
        let sent = try mailbox("Sent Items")
        #expect(sent.flag == .sent)
        #expect(sent.isSpecialUseDeclared == false)

        let drafts = try mailbox("Drafts")
        #expect(drafts.flag == .draft)
        #expect(drafts.isSpecialUseDeclared == false)

        // INBOX is case-insensitively reserved by RFC 3501, so it is canonical
        // whether or not the server declares it.
        let inbox = try mailbox("INBOX")
        #expect(inbox.flag == .inbox)
        #expect(inbox.isSpecialUseDeclared == false)
        #expect(try parsedLine("* LIST () \"/\" \"inbox\"\r\n").flag == .inbox)
        #expect(try parsedLine("* LIST () \"/\" \"Deleted Items\"\r\n").flag == .trash)
    }

    @Test("the heuristic matches the whole name, never a nested last component")
    func heuristicsDoNotMatchSubfolders() throws {
        // `Folder A/Trash` is the user's own subfolder. A last-component
        // heuristic answers `.trash` — plausible-but-wrong, and the consequence
        // is a delete path pointed at real mail.
        let nested = try mailbox("Folder A/Trash")
        #expect(nested.flag == .user("Folder A/Trash"))
        #expect(nested.isSpecialUseDeclared == false)
    }

    @Test("an INBOX-rooted single component resolves, without a general last-component rule")
    func inboxRootedNamespace() throws {
        // Courier, and Dovecot in its maildir++ layout, put every special folder
        // under the INBOX namespace and need not advertise SPECIAL-USE. On
        // whole-name matching alone such an account has no trash, sent, drafts or
        // archive at all, and every folder mutation is refused.
        let directory = try directory("imap-list-inbox-namespace")
        #expect(directory.mailbox(for: .trash)?.name == "INBOX.Trash")
        #expect(directory.mailbox(for: .sent)?.name == "INBOX.Sent")
        #expect(directory.mailbox(for: .draft)?.name == "INBOX.Drafts")
        #expect(directory.mailbox(for: .archive)?.name == "INBOX.Archive")
        #expect(directory.mailbox(for: .spam)?.name == "INBOX.Junk")
        #expect(directory.mailbox(for: .inbox)?.name == "INBOX")

        // The narrowness is the safety. `INBOX.Folder A.Trash` is a subfolder of
        // a subfolder — deeper than one component — so it stays a user label,
        // and the *only* trash the account has is the one directly under INBOX.
        #expect(directory.flag(for: "INBOX.Folder A.Trash") == .user("INBOX.Folder A.Trash"))
        #expect(directory.flag(for: "INBOX.Folder A") == .user("INBOX.Folder A"))
        // A bare trailing delimiter has no component to match.
        #expect(directory.flag(for: "INBOX.") == .user("INBOX."))

        // The depth check earns its place only when the delimiter can occur
        // *inside* a heuristic key, and it can: RFC 3501 allows any single
        // character, so under a space delimiter `INBOX Sent Items` is the
        // two-level `INBOX`→`Sent`→`Items`, not the Sent folder. Dropping the
        // check makes it `.sent` — plausible, and it files sent mail into a
        // stranger's subfolder.
        #expect(try parsedLine("* LIST () \" \" \"INBOX Sent Items\"\r\n").flag
                == .user("INBOX Sent Items"))
        // One component deep under the same delimiter still resolves.
        #expect(try parsedLine("* LIST () \" \" \"INBOX Trash\"\r\n").flag == .trash)

        // Nothing about this rule is INBOX-prefix-only: the hazard case from the
        // other capture is not INBOX-rooted and is unaffected.
        #expect(try self.directory().flag(for: "Folder A/Trash") == .user("Folder A/Trash"))
        // …nor does an unrelated prefix that merely starts with the letters.
        #expect(try parsedLine("* LIST () \".\" \"INBOXES.Trash\"\r\n").flag
                == .user("INBOXES.Trash"))
        // …nor does it fire when the server has no hierarchy at all.
        #expect(try parsedLine("* LIST () NIL \"INBOX.Trash\"\r\n").flag
                == .user("INBOX.Trash"))
    }

    @Test("a mailbox matching nothing becomes a user label, never dropped")
    func unmatchedMailboxIsUserLabel() throws {
        let box = try mailbox("Folder C")
        #expect(box.flag == .user("Folder C"))
        #expect(box.isSpecialUseDeclared == false)
        // Kept in the hierarchy even though it can never be SELECTed.
        #expect(box.isSelectable == false)
        #expect(try mailbox("Sent Items").isSelectable)
    }

    // MARK: - Directory

    @Test("the flag→mailbox direction prefers a declared SPECIAL-USE match")
    func declaredMatchWinsOverHeuristic() throws {
        // The capture has two candidates for `.sent`: `Sent Items` by heuristic
        // and `Folder B` by a declared `\sent`. The declaration wins.
        let resolved = try #require(try directory().mailbox(for: .sent))
        #expect(resolved.name == "Folder B")
        #expect(try directory().mailbox(for: .trash)?.name == "Folder A")
        #expect(try directory().mailbox(for: .user("Folder A/Trash"))?.name == "Folder A/Trash")
    }

    @Test("a flag with no mailbox resolves to nil rather than a guessed name")
    func missingMailboxIsNil() throws {
        // `\Noselect` containers are never offered as a mutation target, and a
        // flag the account has no folder for must be refused upstream — not
        // answered with a SELECT of an invented `"Archive"`.
        #expect(try directory().mailbox(for: .starred) == nil)
        #expect(try directory().mailbox(for: .user("Folder C")) == nil)
    }

    @Test("an unknown mailbox name reads back as a user label")
    func unknownNameIsUserLabel() throws {
        #expect(try directory().flag(for: "Folder Z") == .user("Folder Z"))
        #expect(try directory().flag(for: "Folder B") == .sent)
    }

    // MARK: - Refusals

    @Test("a LIST line whose attributes are not a list is refused")
    func malformedAttributesRefused() throws {
        let responses = try IMAPFetchWire.untaggedResponses(
            Data("* LIST \"/\" \"Folder A\"\r\n".utf8))
        let response = try #require(responses.first)
        // The exact case, not merely `IMAPFetchParseError.self`. With the
        // attribute guard removed this line still throws — `.truncated`, from
        // running off the end one value later — so a type-only expectation
        // passes for the wrong reason and pins nothing.
        #expect(throws: IMAPFetchParseError.unexpectedToken("LIST attributes are not a list")) {
            try IMAPMailboxList.parse(response)
        }
    }

    @Test("a LIST line with no mailbox name is refused")
    func missingNameRefused() throws {
        let truncated = try #require(try IMAPFetchWire.untaggedResponses(
            Data("* LIST (\\HasNoChildren) \"/\"\r\n".utf8)).first)
        #expect(throws: IMAPFetchParseError.truncated) {
            try IMAPMailboxList.parse(truncated)
        }

        let empty = try #require(try IMAPFetchWire.untaggedResponses(
            Data("* LIST (\\HasNoChildren) \"/\" \"\"\r\n".utf8)).first)
        #expect(throws: IMAPFetchParseError.unexpectedToken("LIST mailbox name is missing")) {
            try IMAPMailboxList.parse(empty)
        }
    }
}
