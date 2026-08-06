import Testing
import Foundation
@testable import RavenFeature

/// One undecodable stored entry used to discard the WHOLE outbox — every
/// pending send, every held one, every one awaiting review — silently. These
/// pin the per-entry decode and the fact that the drop is counted, not
/// swallowed.
@Suite("Outbox lenient decode")
@MainActor struct OutboxLenientDecodeTests {
    private func aMessage(_ subject: String) -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "b@x.com")], subject: subject, bodyText: "There")
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The stored queue as mutable JSON objects, so a test can corrupt one
    /// element or add a field this build has never heard of.
    private func storedObjects(_ entries: [OutboxEntry]) throws -> [[String: Any]] {
        let data = try encoder().encode(entries)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func store(_ json: Any, into documents: InMemoryDocumentStore) throws {
        documents.setData(try JSONSerialization.data(withJSONObject: json),
                          forKey: DocumentKeys.outbox)
    }

    @Test("an unreadable entry costs that entry only, not the whole queue")
    func oneBadEntryDoesNotStrandTheRest() async throws {
        let documents = InMemoryDocumentStore()
        let first = OutboxEntry(operation: .send(aMessage("first")))
        let third = OutboxEntry(operation: .send(aMessage("third")))
        var objects: [Any] = try storedObjects([first, third])
        // An entry this build genuinely cannot read: the id is not a UUID.
        // Not merely an absent key — the shape that survived in
        // `MailTransportTLS` was tested only in the absent-key direction.
        var broken = try #require(objects.first as? [String: Any])
        broken["id"] = "not-a-uuid"
        objects.insert(broken, at: 1)
        try store(objects, into: documents)

        let provider = FakeMailProvider()
        let outbox = Outbox(documents: documents, provider: provider)

        #expect(outbox.unreadableEntryCount == 1)
        let pending = outbox.pending()
        #expect(pending.count == 2)
        #expect(pending.map(\.id) == [first.id, third.id])

        await outbox.drain()
        #expect(provider.sentMessages.map(\.subject) == ["first", "third"])
    }

    @Test("a held entry and one awaiting review survive an unreadable neighbour")
    func heldAndReviewEntriesSurvive() throws {
        let documents = InMemoryDocumentStore()
        let held = OutboxEntry(operation: .send(aMessage("held")),
                               holdUntil: Date().addingTimeInterval(600))
        let inFlight = OutboxEntry(operation: .send(aMessage("unknown outcome")),
                                   inFlightAt: Date())
        var objects: [Any] = try storedObjects([held, inFlight])
        objects.append(["operation": "nonsense"])
        try store(objects, into: documents)

        let outbox = Outbox(documents: documents, provider: FakeMailProvider())

        #expect(outbox.unreadableEntryCount == 1)
        // The held send is still queued (just not yet eligible), and the
        // crash-recovery conversion still ran on the in-flight one.
        #expect(outbox.pending().isEmpty)
        #expect(outbox.needsReview().map(\.id) == [inFlight.id])
        #expect(outbox.outcome(for: held.id) == .queued(inFlight: false))
    }

    /// NOT coverage of the per-entry decode — `Codable` ignores unknown keys
    /// on its own, so this passes under a strict whole-array decode too (it
    /// would have passed before the fix). What it pins is that nothing in the
    /// codec, now or later, starts REJECTING unknown keys: Task 18 adds a rich
    /// body field, and an older build must keep sending an entry a newer one
    /// wrote. The unreadable direction is covered by the tests above.
    @Test("an entry carrying a field this build does not know still decodes and sends")
    func unknownFieldIsTolerated() async throws {
        let documents = InMemoryDocumentStore()
        let entry = OutboxEntry(operation: .send(aMessage("from a newer build")))
        var objects = try storedObjects([entry])
        // What Task 18's rich-body field will look like to this build.
        objects[0]["bodyRichText"] = "<p>hello</p>"
        try store(objects, into: documents)

        let provider = FakeMailProvider()
        let outbox = Outbox(documents: documents, provider: provider)

        #expect(outbox.unreadableEntryCount == 0)
        #expect(outbox.pending().map(\.id) == [entry.id])
        await outbox.drain()
        #expect(provider.sentMessages.map(\.subject) == ["from a newer build"])
    }

    @Test("a wholly readable queue reports no unreadable entries")
    func cleanQueueCountsZero() throws {
        let documents = InMemoryDocumentStore()
        try store(try storedObjects([OutboxEntry(operation: .send(aMessage("ok")))]),
                  into: documents)
        #expect(Outbox(documents: documents, provider: FakeMailProvider())
            .unreadableEntryCount == 0)
    }

    // MARK: The document itself is unreadable

    @Test("a truncated queue document is reported as unreadable, not as an empty outbox")
    func truncatedDocumentIsFlagged() throws {
        let documents = InMemoryDocumentStore()
        let whole = try JSONSerialization.data(
            withJSONObject: try storedObjects([OutboxEntry(operation: .send(aMessage("lost")))]))
        // A write that did not finish: valid bytes, cut short.
        documents.setData(Data(whole.prefix(whole.count / 2)), forKey: DocumentKeys.outbox)

        let outbox = Outbox(documents: documents, provider: FakeMailProvider())

        #expect(outbox.queueDocumentUnreadable)
        // The count cannot speak here — nothing parsed, so there is nothing to
        // enumerate — which is exactly why the flag exists alongside it.
        #expect(outbox.unreadableEntryCount == 0)
        #expect(outbox.pending().isEmpty)
    }

    @Test("an object envelope where an array was expected is reported as unreadable")
    func objectEnvelopeIsFlagged() throws {
        let documents = InMemoryDocumentStore()
        // What a future build wrapping the queue in an envelope would store.
        try store(["version": 2, "entries": try storedObjects(
            [OutboxEntry(operation: .send(aMessage("lost")))])], into: documents)

        let outbox = Outbox(documents: documents, provider: FakeMailProvider())

        #expect(outbox.queueDocumentUnreadable)
        #expect(outbox.unreadableEntryCount == 0)
        #expect(outbox.pending().isEmpty)
    }

    @Test("an outbox that was never written is not reported as unreadable")
    func absentDocumentIsNotUnreadable() {
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        #expect(!outbox.queueDocumentUnreadable)
        #expect(outbox.unreadableEntryCount == 0)
    }

    @Test("a readable queue is not reported as an unreadable document")
    func readableDocumentIsNotFlagged() throws {
        let documents = InMemoryDocumentStore()
        try store(try storedObjects([OutboxEntry(operation: .send(aMessage("ok")))]),
                  into: documents)
        #expect(!Outbox(documents: documents, provider: FakeMailProvider())
            .queueDocumentUnreadable)
    }

    @Test("the unreadable count reaches the runtime snapshot the Settings attention group reads")
    func runtimeSurfacesTheCount() throws {
        let host = FakeHostServices()
        let documents = try #require(host.documents as? InMemoryDocumentStore)
        try store([["operation": "nonsense"], ["operation": "nonsense"]], into: documents)

        let runtime = RavenRuntime(host: host)
        runtime.refreshOutboxSnapshots()

        #expect(runtime.outboxUnreadableEntryCount == 2)
        #expect(!runtime.outboxQueueUnreadable)
        // Nothing decodable was in the queue, so the two lists the attention
        // group already rendered are empty — without this count the group
        // would render nothing at all and two never-to-be-sent operations
        // would be invisible.
        #expect(runtime.outboxDeadLettered.isEmpty)
        #expect(runtime.outboxNeedsReview.isEmpty)
    }

    @Test("an unreadable queue document reaches the runtime snapshot too")
    func runtimeSurfacesTheUnreadableDocument() throws {
        let host = FakeHostServices()
        let documents = try #require(host.documents as? InMemoryDocumentStore)
        try store(["version": 2, "entries": []], into: documents)

        let runtime = RavenRuntime(host: host)
        runtime.refreshOutboxSnapshots()

        #expect(runtime.outboxQueueUnreadable)
        // Zero, and that is the whole point: without the flag the attention
        // group would see three empty things and render nothing, which is
        // exactly what a genuinely empty outbox looks like.
        #expect(runtime.outboxUnreadableEntryCount == 0)
        #expect(runtime.outboxDeadLettered.isEmpty)
        #expect(runtime.outboxNeedsReview.isEmpty)
    }
}
