import Testing
import Foundation
@testable import RavenFeature

// The send-path half of `RichBodyTests`, in its own file to keep both under the
// line cap. The model and decode rules are next door; these two suites are
// about what happens to a rich body on the way OUT — the signature rebuild that
// has silently dropped fields before, and the stored queue that one unreadable
// entry used to empty.

/// Signing a message rebuilds it field by field, and that rebuild has already
/// dropped `attachments` and `icsReply` once. `richBody` is the newest field in
/// it.
@Suite("Rich body through the signature rebuild")
@MainActor struct RichBodySignatureTests {
    /// Everything here is in-process (`FakeMailProvider`), but the call is
    /// send-shaped, so it gets a deadline rather than the ability to hang the
    /// suite.
    private func send(_ message: OutgoingMessage, store: DocumentMailStore,
                      outbox: Outbox) async throws {
        let work = Task {
            _ = try await SendAttempt.send(message, draftID: nil, outbox: outbox,
                                           store: store, drain: outbox.drain)
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            work.cancel()
        }
        defer { deadline.cancel() }
        try await work.value
    }

    @Test("signing a formatted message keeps its formatting and both bodies in step")
    func signaturePreservesTheRichBody() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a@example.test",
                                          displayName: "A", signature: "Best,\nA"))
        let rich = RichBody(text: "Hello there",
                            spans: [RichBody.Span(start: 0, length: 5, kind: .bold)])
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.test")],
                                      subject: "Subject 1", bodyText: "Hello there",
                                      accountID: "a1", richBody: rich)

        try await send(message, store: store, outbox: outbox)

        #expect(provider.sentMessages.count == 1)
        let sent = try #require(provider.sentMessages.first)
        #expect(sent.bodyText == "Hello there\n-- \nBest,\nA")
        // Dropped here, the message would go out unformatted for every account
        // that has a signature — i.e. the normal configuration.
        #expect(sent.richBody?.spans.map(\.kind) == [.bold])
        // The two bodies are one invariant, and the appended signature is
        // plain: no span reaches into it.
        #expect(sent.richBody?.text == sent.bodyText)
        #expect(sent.richBody?.spans.allSatisfy { $0.start + $0.length <= 11 } == true)
    }
}

/// The queue-level half of the decode rule: whatever a message's body does, an
/// outbox entry must survive it.
@Suite("Rich body in the send queue")
@MainActor struct RichBodyQueueDecodeTests {
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func message(_ subject: String, rich: RichBody? = nil) -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "b@example.test")], subject: subject,
                        bodyText: rich?.text ?? "There", richBody: rich)
    }

    /// The stored queue as mutable JSON, so one entry can be aged back to the
    /// pre-M6 shape and another corrupted, in the same document.
    private func storedObjects(_ entries: [OutboxEntry]) throws -> [[String: Any]] {
        let data = try encoder().encode(entries)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// Rewrites the `OutgoingMessage` inside one stored entry.
    ///
    /// `OutboxEntry.Operation` is a synthesized-`Codable` enum, so the stored
    /// shape is `{"operation": {"send": {"_0": {…the message…}}}}`. Editing
    /// `operation["send"]` directly writes a SIBLING of `_0` that the message
    /// never sees — a corruption the decoder cannot even notice, and a test
    /// built on it asserts nothing. The `#require`s below fail loudly if that
    /// nesting ever changes, rather than letting the tests go quietly vacuous
    /// again.
    private func editingMessage(_ entry: inout [String: Any],
                                _ edit: (inout [String: Any]) -> Void) throws {
        var operation = try #require(entry["operation"] as? [String: Any])
        var send = try #require(operation["send"] as? [String: Any])
        var message = try #require(send["_0"] as? [String: Any])
        edit(&message)
        send["_0"] = message
        operation["send"] = send
        entry["operation"] = operation
    }

    @Test("a queue holding one new-format and one old-format entry decodes to two")
    func mixedFormatQueueDecodesWhole() throws {
        let rich = RichBody(text: "Formatted",
                            spans: [RichBody.Span(start: 0, length: 9, kind: .bold)])
        let new = OutboxEntry(operation: .send(message("new", rich: rich)))
        // Written WITH a rich body and then aged back to the pre-M6 shape
        // below, so this really is one document containing both formats —
        // starting from a message that never had one would prove only that
        // `nil` decodes to `nil`.
        let old = OutboxEntry(operation: .send(message("old", rich: rich)))
        var objects = try storedObjects([new, old])
        try editingMessage(&objects[1]) { message in
            #expect(message["richBody"] != nil, "the fixture was not aged from a rich document")
            message.removeValue(forKey: "richBody")
            message["bodyText"] = "There"
        }

        let load = OutboxQueueCodec.load(
            try JSONSerialization.data(withJSONObject: objects), decoder: decoder())

        #expect(load.entries.count == 2)
        #expect(load.unreadableEntryCount == 0)
        #expect(load.documentUnreadable == false)
        guard case .send(let first) = load.entries[0].operation,
              case .send(let second) = load.entries[1].operation else {
            Issue.record("expected two sends")
            return
        }
        #expect(first.richBody?.spans.map(\.kind) == [.bold])
        #expect(second.richBody == nil)
        #expect(second.bodyText == "There")
    }

    @Test("an entry whose rich body is unreadable still transmits, unformatted")
    func unreadableRichBodyDoesNotStrandTheEntry() throws {
        let entry = OutboxEntry(operation: .send(message("queued")))
        var objects = try storedObjects([entry])
        try editingMessage(&objects[0]) { message in
            // A shape this build cannot read at all, under the new key, ON THE
            // MESSAGE — not beside it, where the decoder would never look.
            message["richBody"] = ["spans": "not an array"]
        }

        let load = OutboxQueueCodec.load(
            try JSONSerialization.data(withJSONObject: objects), decoder: decoder())

        // The message the user was told was queued still exists. Losing it
        // would be a send that silently ceased to be — the failure this whole
        // rule is shaped around.
        #expect(load.entries.count == 1)
        #expect(load.unreadableEntryCount == 0)
        guard case .send(let queued) = load.entries.first?.operation else {
            Issue.record("the queued send did not survive")
            return
        }
        #expect(queued.subject == "queued")
        #expect(queued.bodyText == "There")
        #expect(queued.richBody == nil)
    }
}
