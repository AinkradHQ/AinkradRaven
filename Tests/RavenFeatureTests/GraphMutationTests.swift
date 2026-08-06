import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// `GraphVocabulary` + `GraphMutations.applyLabels`: the canonical flags of Task 2
/// translated into the three requests a Graph mailbox actually has.
///
/// **Verified against recorded fixtures and `StubURLProtocol` only.** There is no
/// Azure app registration, so nothing here has met a live Graph endpoint; live
/// verification is Task 24's.
@Suite("Graph mutations")
@MainActor
struct GraphMutationTests {

    /// Arms the stub to serve the conversation-expansion fixture for the `GET` and
    /// an empty JSON object for every write, and returns the recorder.
    ///
    /// Callers must `defer` the teardown themselves — `StubURLProtocol`'s state is
    /// process-global.
    private func arm() throws -> RecordedRequests {
        let recorded = RecordedRequests()
        let conversation = try graphFixture("graph-conversation-write")
        StubURLProtocol.handler = { request in
            recorded.record(request)
            if request.httpMethod == "GET" { return (200, [:], conversation) }
            return (200, [:], Data("{}".utf8))
        }
        return recorded
    }

    private func apply(_ action: ThreadAction, threadIDs: [String] = ["AAQkCONV-1"])
        async throws -> RecordedRequests {
        try await apply(action.mutation(threadIDs: threadIDs))
    }

    private func apply(_ mutation: FlagMutation) async throws -> RecordedRequests {
        let recorded = try arm()
        let rendered = GraphVocabulary().render(mutation)
        try await graphBounded("applyLabels") {
            try await makeGraphProvider().applyLabels(rendered)
        }
        return recorded
    }

    /// Clears **both** halves of `StubURLProtocol`'s process-global state, not just
    /// the one this suite sets. An incomplete reset of a shared global is how a test
    /// starts depending on run order.
    private func teardown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.transportFailure = nil
    }

    // MARK: The conversation expansion the writes are built on

    /// Every assertion below indexes into the fixture's messages, so the fixture's
    /// own shape is pinned first: two messages, in this order, with these
    /// categories. Without this a later expectation could pass because the fixture
    /// quietly held one message, or none.
    @Test("the write fixture holds the two conversation members the writes address")
    func writeFixtureShape() throws {
        let list = try JSONDecoder().decode(GraphMessageListDTO.self,
                                            from: try graphFixture("graph-conversation-write"))
        let messages = try #require(list.value)
        #expect(messages.count == 2)
        #expect(messages.map(\.id) == ["AAMkMSG-1", "AAMkMSG-2"])
        #expect(messages[0].categories == ["Category A", "Category B", "archive"])
        #expect(messages[1].categories == [])
    }

    /// A mutation names CONVERSATION ids and Graph has no conversation resource, so
    /// each one is expanded to its messages before anything is written. Pinned on
    /// the request itself, including the `$select` — the default projection would
    /// drag every body across the wire to set one boolean.
    @Test("a mutation expands the conversation to its messages before writing")
    func conversationIsExpandedFirst() async throws {
        defer { teardown() }
        let recorded = try await apply(.star(true))

        let entries = recorded.all
        #expect(entries.count == 3)
        #expect(entries[0].method == "GET")
        #expect(entries[0].url.contains("$filter=conversationId%20eq%20'AAQkCONV-1'"))
        #expect(entries[0].url.contains("$select=id,categories"))
        // One write per message, addressed by MESSAGE id — never by the
        // conversation id, which is not a message resource.
        #expect(entries.dropFirst().map(\.path)
                == ["messages/AAMkMSG-1", "messages/AAMkMSG-2"])
    }

    // MARK: unread -> isRead

    /// `ThreadAction.setRead` is canonically the `.unread` flag, and Graph's stored
    /// property is the opposite polarity. Both directions are asserted, because a
    /// vocabulary that lost the inversion turns "mark unread" into "mark read" and
    /// only ONE of these two would catch it.
    @Test("unread translates to isRead, inverted")
    func unreadTranslatesToIsRead() async throws {
        defer { teardown() }
        let read = try await apply(.setRead(true))
        let readWrites = read.all.filter { $0.method == "PATCH" }
        #expect(readWrites.count == 2)
        for entry in readWrites {
            let json = try #require(entry.json)
            #expect(json["isRead"] as? Bool == true)
            // Nothing else was touched: a mark-read must not also clear the star.
            #expect(json.keys.sorted() == ["isRead"])
        }
        #expect(read.all.contains { $0.path.hasSuffix("/move") } == false)

        let unread = try await apply(.setRead(false))
        let unreadWrites = unread.all.filter { $0.method == "PATCH" }
        #expect(unreadWrites.count == 2)
        for entry in unreadWrites {
            let json = try #require(entry.json)
            #expect(json["isRead"] as? Bool == false)
        }
    }

    // MARK: starred -> flag.flagStatus

    /// The star is `flag.flagStatus`, nested — not a top-level `flagStatus`, and not
    /// a boolean. Asserted through the nested object so a payload injected at the
    /// wrong level fails.
    @Test("starred translates to a nested flag.flagStatus")
    func starredTranslatesToFlagStatus() async throws {
        defer { teardown() }
        let starred = try await apply(.star(true))
        let writes = starred.all.filter { $0.method == "PATCH" }
        #expect(writes.count == 2)
        for entry in writes {
            let json = try #require(entry.json)
            #expect(json.keys.sorted() == ["flag"])
            let flag = try #require(json["flag"] as? [String: Any])
            #expect(flag["flagStatus"] as? String == "flagged")
        }

        // Unstarring is `notFlagged`, NOT `complete`. `complete` is the user saying
        // they finished the task the flag stood for, which Graph records; it reads
        // as unstarred (`GraphMapping.message`) so the two are indistinguishable in
        // the list, which is exactly why the write has to be pinned here.
        let unstarred = try await apply(.star(false))
        let cleared = unstarred.all.filter { $0.method == "PATCH" }
        #expect(cleared.count == 2)
        for entry in cleared {
            let json = try #require(entry.json)
            let flag = try #require(json["flag"] as? [String: Any])
            #expect(flag["flagStatus"] as? String == "notFlagged")
        }
    }

    // MARK: archive / trash -> move

    /// Archive is canonically `remove: [.inbox]` with nothing added, so the
    /// destination has to be *derived*. It is a `/move` to the well-known archive
    /// folder and nothing else — no `PATCH`, because archiving does not change a
    /// message's read state or its star.
    @Test("archive becomes a move to the well-known archive folder")
    func archiveBecomesAMove() async throws {
        defer { teardown() }
        let recorded = try await apply(.archive)

        let entries = recorded.all
        #expect(entries.count == 3)
        #expect(entries.filter { $0.method == "PATCH" }.isEmpty)
        let moves = entries.filter { $0.path.hasSuffix("/move") }
        #expect(moves.count == 2)
        #expect(moves.map(\.path) == ["messages/AAMkMSG-1/move", "messages/AAMkMSG-2/move"])
        for move in moves {
            let json = try #require(move.json)
            #expect(json.keys.sorted() == ["destinationId"])
            #expect(json["destinationId"] as? String == "archive")
        }
    }

    /// Trash is `add: [.trash], remove: [.inbox]`, and the ADDED folder must win —
    /// deriving from the removal instead would archive a thread the user deleted.
    ///
    /// The destination is Graph's `deleteditems`, not `trash`: the canonical flag's
    /// own name is a plausible spelling and a 404 on every single delete.
    @Test("trash becomes a move to deleteditems, not to the archive and not to 'trash'")
    func trashBecomesAMoveToDeletedItems() async throws {
        defer { teardown() }
        let recorded = try await apply(.trash)

        let moves = recorded.all.filter { $0.path.hasSuffix("/move") }
        #expect(moves.count == 2)
        var destinations: [String] = []
        for move in moves {
            let json = try #require(move.json)
            destinations.append(try #require(json["destinationId"] as? String))
        }
        #expect(destinations == ["deleteditems", "deleteditems"])
    }

    // MARK: user labels -> categories

    /// User labels are Graph **categories**, and Graph replaces the array whole —
    /// there is no add/remove verb. So the current value is read back and edited.
    ///
    /// The fixture is chosen so the wrong rule is plausible rather than absent: the
    /// two messages start with DIFFERENT category arrays, so an implementation that
    /// sent the additions alone would produce `["Category C"]` for both — a
    /// perfectly well-formed payload that silently deletes `Category B` and
    /// `archive` from the first message.
    @Test("user labels become categories, merged into what the message already had")
    func userLabelsBecomeMergedCategories() async throws {
        defer { teardown() }
        let recorded = try await apply(.label(add: ["Category C"], remove: ["Category A"]))

        let writes = recorded.all.filter { $0.method == "PATCH" }
        #expect(writes.count == 2)
        var arrays: [[String]] = []
        for write in writes {
            let json = try #require(write.json)
            arrays.append(try #require(json["categories"] as? [String]))
        }
        // Message 1 keeps `Category B` AND `archive`; message 2 gains only the new
        // one. `archive` surviving is the second half: a vocabulary that read bare
        // well-known names as folders would have classified that category as the
        // archive FOLDER and dropped it here.
        #expect(arrays == [["Category B", "archive", "Category C"], ["Category C"]])
        // Categories are the only thing a label mutation touches, and no move is
        // issued — a category is not a folder.
        for write in writes {
            let json = try #require(write.json)
            #expect(json.keys.sorted() == ["categories"])
        }
        #expect(recorded.all.contains { $0.path.hasSuffix("/move") } == false)
    }

    // MARK: Ordering

    /// `/move` mints a NEW message id — the message is recreated in the destination
    /// — so a `PATCH` issued afterwards addresses an id that no longer exists.
    /// Asserted as the actual request order for one message, not as a comment.
    @Test("properties are patched before the move, never after")
    func patchPrecedesTheMove() async throws {
        defer { teardown() }
        // Archive-and-mark-read: one canonical mutation carrying both a property
        // and a folder change. Not expressible as a single `ThreadAction`, which is
        // why it is built from `FlagMutation` directly.
        let recorded = try await apply(FlagMutation(threadIDs: ["AAQkCONV-1"],
                                                    remove: [.inbox, .unread]))

        let entries = recorded.all
        #expect(entries.count == 5)
        #expect(entries.dropFirst().map { "\($0.method) \($0.path)" } == [
            "PATCH messages/AAMkMSG-1",
            "POST messages/AAMkMSG-1/move",
            "PATCH messages/AAMkMSG-2",
            "POST messages/AAMkMSG-2/move",
        ])
        let patched = try #require(entries[1].json)
        #expect(patched["isRead"] as? Bool == true)
        let moved = try #require(entries[2].json)
        #expect(moved["destinationId"] as? String == "archive")
    }

    // MARK: Degenerate inputs

    /// A mutation that renders to nothing must cost nothing — not even the
    /// conversation expansion, which is a round trip per thread.
    @Test("an empty mutation issues no request at all")
    func emptyMutationIssuesNoRequest() async throws {
        defer { teardown() }
        let recorded = try arm()
        try await graphBounded("applyLabels(empty)") {
            try await makeGraphProvider()
                .applyLabels(LabelMutation(threadIDs: ["AAQkCONV-1"]))
        }
        #expect(recorded.all.isEmpty)
    }

    /// A conversation Graph knows nothing about must THROW, not return normally.
    /// Returning would tell `Outbox` the label was applied when no message was
    /// touched, and the entry would leave the queue as a success.
    @Test("a conversation with no messages throws rather than reporting success")
    func unknownConversationThrows() async throws {
        let recorded = RecordedRequests()
        StubURLProtocol.handler = { request in
            recorded.record(request)
            return (200, [:], Data(#"{"value":[]}"#.utf8))
        }
        defer { teardown() }

        let rendered = GraphVocabulary().render(ThreadAction.star(true)
            .mutation(threadIDs: ["AAQkGHOST"]))
        // Bounded like every other network-shaped await, including this one: a
        // `do/catch` site is exactly where Task 19's own deadline was missed.
        await #expect(throws: MailError.unknownThread("AAQkGHOST")) {
            try await graphBounded("applyLabels(unknown)") {
                try await makeGraphProvider().applyLabels(rendered)
            }
        }
        // The expansion happened and nothing was written after it.
        #expect(recorded.all.map(\.method) == ["GET"])
    }
}
