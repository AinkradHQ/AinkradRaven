import Testing
import Foundation
@testable import RavenFeature

/// Pure wire→domain mapping, against the recorded Graph fixtures. Every
/// fixture here is built so that a plausible WRONG rule produces a wrong
/// answer rather than an absent one:
///
/// - `graph-messages.json` gives two DIFFERENT conversations the same subject
///   and one conversation two different subjects, so subject-based threading
///   both merges and splits incorrectly and cannot pass by luck.
/// - `graph-folders.json` names an `archive` folder "Folder B" and a user
///   folder "Archive", so a mapper keying on `displayName` gets both wrong.
/// - `graph-profile.json` gives `mail` and `userPrincipalName` different
///   values, so reading the wrong field is a failure and not a tie.
@Suite("Graph mapping")
struct GraphMappingTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func messages(_ name: String = "graph-messages") throws -> [GraphMessageDTO] {
        let list = try JSONDecoder().decode(GraphMessageListDTO.self, from: fixture(name))
        return try #require(list.value)
    }

    // MARK: Threading

    @Test("threads are grouped by conversationId, not by subject")
    func groupsByConversationID() throws {
        let dtos = try messages()
        #expect(dtos.count == 3)   // the fixture reached this code at all
        let threads = GraphMapping.threads(dtos, accountID: "a1")

        // conv-1 owns m1 ("Subject 1") and m3 ("Subject 3"); conv-2 owns m2,
        // whose subject is ALSO "Subject 1". Subject grouping would give one
        // thread of two and one of one, with different ids.
        #expect(threads.map(\.id) == ["conv-1", "conv-2"])
        #expect(threads.map { $0.messages.map(\.id) } == [["m3", "m1"], ["m2"]])
        #expect(threads.allSatisfy { $0.accountID == "a1" })
    }

    /// `MailThread.messages` is documented oldest-first and everything
    /// downstream depends on it; Graph lists newest-first, so this is a
    /// reversal, not a pass-through.
    @Test("messages within a thread are oldest-first even though Graph lists newest-first")
    func messagesAreOldestFirst() throws {
        let threads = GraphMapping.threads(try messages(), accountID: "a1")
        let conversation = try #require(threads.first { $0.id == "conv-1" })
        #expect(conversation.messages.count == 2)
        let dates = conversation.messages.map(\.date)
        #expect(dates == dates.sorted())
        // The observable consequence, not just the ordering itself.
        #expect(conversation.subject == "Subject 3")
        #expect(conversation.messages.last?.id == "m1")
    }

    @Test("a message maps its addresses, ids, dates and folder in full")
    func messageFieldsMap() throws {
        let dtos = try messages()
        let m1 = GraphMapping.message(dtos[0])

        #expect(m1.id == "m1")
        #expect(m1.threadID == "conv-1")
        #expect(m1.rfc822MessageID == "<m1@example.test>")
        #expect(m1.subject == "Subject 1")
        #expect(m1.from?.email == "a@example.test")
        #expect(m1.from?.name == "Person A")
        #expect(m1.to.map(\.email) == ["b@example.test"])
        #expect(m1.cc.map(\.email) == ["c@example.test"])
        #expect(m1.snippet == "Preview 1")
        #expect(m1.hasAttachments)
        // Folder id first, then categories — the folder is the system label
        // and the categories are the user ones.
        #expect(m1.labelIDs == ["folder-b-id", "Category A"])
        #expect(m1.date == ISO8601DateFormatter().date(from: "2026-01-03T10:00:00Z"))
    }

    /// `"complete"` is a flag the user has FINISHED with. Collapsing it into
    /// starred (the `flagStatus != "notFlagged"` shape) refills the starred
    /// list with everything the user has already dealt with.
    @Test("only flagStatus == flagged is starred; complete and absent are not")
    func flagStatusMapsToStarred() throws {
        let dtos = try messages()
        let mapped = dtos.map(GraphMapping.message)
        #expect(mapped.count == 3)
        #expect(mapped[0].isStarred == false)   // "complete"
        #expect(mapped[1].isStarred)            // "flagged"
        #expect(mapped[2].isStarred == false)   // absent
    }

    /// Graph's field is positive where Gmail's is a negative label, so this is
    /// the place an inversion would hide. An ABSENT `isRead` must read unread:
    /// showing new mail as already-read is the failure that loses it.
    @Test("isRead maps directly, and an absent isRead is unread")
    func isReadMaps() throws {
        let mapped = try messages().map(GraphMapping.message)
        #expect(mapped.count == 3)
        #expect(mapped[0].isRead)
        #expect(mapped[1].isRead == false)
        #expect(mapped[2].isRead == false)      // absent
    }

    @Test("a fractional-seconds timestamp parses rather than falling back to the epoch")
    func fractionalSecondsParse() throws {
        let mapped = try messages().map(GraphMapping.message)
        #expect(mapped.count == 3)
        #expect(mapped[1].date != Date(timeIntervalSince1970: 0))
        #expect(abs(mapped[1].date.timeIntervalSince1970
                    - 1_767_348_000.5) < 0.001)
    }

    @Test("an unparseable timestamp degrades to the epoch instead of failing the page")
    func unparseableTimestampDegrades() {
        #expect(GraphMapping.date("not a date") == Date(timeIntervalSince1970: 0))
        #expect(GraphMapping.date(nil) == Date(timeIntervalSince1970: 0))
    }

    // MARK: Bodies

    /// The HTML→plainText policy, byte-identical to `GmailMapping.body` and
    /// `IMAPFetchParser.body`: `html` keeps the ORIGINAL markup and the
    /// sanitiser's output goes only onto `plainText`.
    @Test("html is stored raw and only plainText is sanitised")
    func bodyKeepsRawHTMLAndSanitisesOnlyPlainText() throws {
        let dto = try JSONDecoder().decode(GraphMessageDTO.self, from: fixture("graph-message"))
        let body = GraphMapping.body(dto)

        let html = try #require(body.html)
        // Raw: the tags are still there, including the ones the sanitiser
        // would have removed. This is what "Show original" renders.
        #expect(html.contains("<blockquote><p>Quoted history 1</p></blockquote>"))
        #expect(html.contains("<script>alert('x')</script>"))
        #expect(html.contains("<style>"))

        // Sanitised: no markup survives onto the text path, and the script's
        // CONTENTS are gone rather than merely its tags.
        #expect(body.plainText.contains("<") == false)
        #expect(body.plainText.contains("alert") == false)
        #expect(body.plainText.contains("color: red") == false)
        #expect(body.plainText.contains("Reply 1"))
    }

    /// `uniqueBody` is the message without the quoted conversation history —
    /// the whole reason Graph offers it — so the default text rendering uses
    /// it while `html` still carries everything.
    @Test("plainText comes from uniqueBody while html still carries the full body")
    func plainTextPrefersUniqueBody() throws {
        let dto = try JSONDecoder().decode(GraphMessageDTO.self, from: fixture("graph-message"))
        let body = GraphMapping.body(dto)
        #expect(body.plainText.contains("Reply 1"))
        #expect(body.plainText.contains("Quoted history 1") == false)
        let html = try #require(body.html)
        #expect(html.contains("Quoted history 1"))
        #expect(body.messageID == "m1")
    }

    /// Whenever `uniqueBody` was not `$select`ed, the full body must still
    /// produce readable text rather than an empty pane.
    @Test("with no uniqueBody, plainText falls back to the sanitised full body")
    func plainTextFallsBackToBody() throws {
        let json = Data("""
        {"id":"m5","body":{"contentType":"html",
         "content":"<p>Reply 1</p><blockquote>Quoted history 1</blockquote>"}}
        """.utf8)
        let dto = try JSONDecoder().decode(GraphMessageDTO.self, from: json)
        let body = GraphMapping.body(dto)
        #expect(body.plainText.contains("Reply 1"))
        #expect(body.plainText.contains("Quoted history 1"))
        #expect(body.plainText.contains("<") == false)
    }

    /// A `"text"` body is already plain and must NOT be run through the
    /// sanitiser, which would eat a literal `<` in ordinary prose.
    @Test("a text/plain body is passed through verbatim and stores no html")
    func textBodyIsNotSanitised() throws {
        let json = Data("""
        {"id":"m6","body":{"contentType":"text","content":"5 < 6 and 7 > 6"}}
        """.utf8)
        let dto = try JSONDecoder().decode(GraphMessageDTO.self, from: json)
        let body = GraphMapping.body(dto)
        #expect(body.plainText == "5 < 6 and 7 > 6")
        #expect(body.html == nil)
    }

    // MARK: Folders

    /// `wellKnownName`, not `displayName`, decides system-ness. The fixture
    /// names the archive "Folder B" and a user folder "Archive" precisely so a
    /// display-name heuristic fails loudly.
    @Test("folder kind comes from wellKnownName, never from the display name")
    func folderKindFromWellKnownName() throws {
        let dto = try JSONDecoder().decode(GraphFolderListDTO.self, from: fixture("graph-folders"))
        let labels = GraphMapping.labels(dto)
        #expect(labels.count == 3)
        #expect(labels.map(\.id) == ["folder-a-id", "folder-b-id", "folder-c-id"])
        #expect(labels.map(\.name) == ["Folder A", "Folder B", "Archive"])
        #expect(labels.map(\.kind) == [.user, .system, .user])
    }

    // MARK: Delta

    @Test("a delta maps changed and removed conversations, and the token is a bare string")
    func deltaMapsChangedAndRemoved() throws {
        let page = try JSONDecoder().decode(GraphMessageListDTO.self, from: fixture("graph-delta"))
        let entries = try #require(page.value)
        #expect(entries.count == 5)
        let token = try #require(GraphMapping.deltaToken(inLink: page.deltaLink))
        // A bare token, not the link — this is what goes into `syncCursor`.
        #expect(token == "DELTA-TOKEN-2")
        #expect(token.contains("http") == false)

        let delta = GraphMapping.delta(entries: entries, newCursor: token)
        #expect(delta.newCursor == "DELTA-TOKEN-2")
        #expect(delta.changedThreadIDs == ["conv-1", "conv-3"])
        #expect(delta.removedThreadIDs == ["conv-2"])
    }

    /// A `@removed` entry with no `conversationId` cannot be attributed to a
    /// thread. The shape this would naturally collapse into — using the message
    /// id — hands `SyncEngine` an id that is not a thread id at all.
    @Test("a removed entry with no conversationId is dropped, never filed under its message id")
    func removedWithoutConversationIsDropped() throws {
        let page = try JSONDecoder().decode(GraphMessageListDTO.self, from: fixture("graph-delta"))
        let delta = GraphMapping.delta(entries: try #require(page.value), newCursor: "t")
        #expect(delta.removedThreadIDs.contains("m9") == false)
        #expect(delta.changedThreadIDs.contains("m9") == false)
    }

    /// A conversation that both gained and lost a message is CHANGED: refetching
    /// it is what resolves which messages remain. Reporting it as removed would
    /// delete a conversation the user still has mail in. (`conv-1` appears in
    /// the fixture as both a change on `m1` and a removal on `m4`.)
    @Test("a conversation that both changed and lost a message is changed, not removed")
    func changeWinsOverRemovalForTheSameConversation() throws {
        let page = try JSONDecoder().decode(GraphMessageListDTO.self, from: fixture("graph-delta"))
        let delta = GraphMapping.delta(entries: try #require(page.value), newCursor: "t")
        #expect(delta.changedThreadIDs.contains("conv-1"))
        #expect(delta.removedThreadIDs.contains("conv-1") == false)
    }

    @Test("a link with no delta token yields nil rather than a bogus cursor")
    func deltaTokenAbsent() {
        #expect(GraphMapping.deltaToken(inLink: nil) == nil)
        #expect(GraphMapping.deltaToken(
            inLink: "https://graph.microsoft.com/v1.0/me/messages?$skiptoken=PAGE-2") == nil)
        #expect(GraphMapping.deltaToken(inLink: "https://x.test/d?$deltatoken=") == nil)
    }

    // MARK: The threading decision itself

    /// Task 19's criterion is that `LocalThreading` is not needed here **and
    /// the code says so**. A comment claiming a property a test cannot observe
    /// is one of this branch's recurring vacuity shapes, so this asserts the
    /// observable half — no Graph source references `LocalThreading` — as well
    /// as the stated half.
    @Test("no Graph source calls LocalThreading, and GraphMapping says why")
    func graphDoesNotUseLocalThreading() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appending(path: "Sources/RavenFeature/Provider/Graph")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(names.count >= 4, "expected the Graph provider's sources, found \(names)")

        for name in names.sorted() {
            let source = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
            #expect(code.contains("LocalThreading") == false,
                    "\(name): Graph threads server-side via conversationId")
        }
        let mapping = try String(contentsOf: directory.appending(path: "GraphMapping.swift"),
                                 encoding: .utf8)
        #expect(mapping.contains("LocalThreading"),
                "GraphMapping must state, in prose, why local threading is not used")
    }
}
