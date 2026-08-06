import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// `label_with_reason`: that it IS the plain `label` tool plus a local record,
/// that it is local-first in that order, that a bad reason or an unknown id
/// costs nothing, and that the reason never reaches a provider.
///
/// A suite of its own rather than more of `RavenMCPServerTests`, which already
/// owns the tool table and the send path — the same split
/// `RavenMCPBundleBySenderTests` made.
@Suite("MCP label_with_reason")
@MainActor struct RavenMCPLabelWithReasonTests {
    /// One account, two labelled threads, and — deliberately — the SAME
    /// document store behind the mail store and the outbox, so
    /// `InMemoryDocumentStore.writeLog` records both families of write in one
    /// ordered list and "store first, outbox second" becomes observable.
    private func reasonFixture() throws -> (store: DocumentMailStore, outbox: Outbox,
                                            provider: FakeMailProvider,
                                            documents: InMemoryDocumentStore) {
        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: documents, provider: provider)
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a1@example.test",
                                          displayName: "A1", state: .ready))
        for id in ["t1", "t2"] {
            try store.upsertThread(MailThread(id: id, accountID: "a1", messages: [
                MailMessage(id: "m-\(id)", threadID: id, from: MailAddress(email: "b@example.test"),
                            subject: "Subject \(id)", date: Date(), labelIDs: ["INBOX"],
                            snippet: "s")
            ]))
        }
        #expect(store.summaries(accountID: "a1", months: UnifiedInbox.recentMonths()).count == 2)
        return (store, outbox, provider, documents)
    }

    private func queuedMutations(_ outbox: Outbox) -> [LabelMutation] {
        outbox.pending().compactMap { entry in
            if case .labels(let mutation) = entry.operation { return mutation }
            return nil
        }
    }

    /// The criterion this whole tool hangs on: it is `label` plus a record, so
    /// the queued mutation must be the byte-identical one the plain `label`
    /// tool queues. Written as an equality between two runs of the REAL tools
    /// over identical fixtures rather than against a hand-written expected
    /// mutation — a hand-written one would have to be spelled in Gmail's
    /// vocabulary here, and would then pass even if `label_with_reason` stopped
    /// going through `ThreadAction`/`LabelVocabulary` at all.
    @Test("label_with_reason queues the identical LabelMutation the plain label tool queues")
    func labelWithReasonMutationIsIdenticalToLabel() async throws {
        let plain = try reasonFixture()
        let reasoned = try reasonFixture()

        let plainResult = await RavenMCPOperations.run(
            "label", arguments: #"{"thread_ids":["t1","t2"],"add":["L1"],"remove":["INBOX"]}"#,
            store: plain.store, outbox: plain.outbox)
        let reasonedResult = await RavenMCPOperations.run(
            "label_with_reason",
            arguments: #"{"thread_ids":["t1","t2"],"add":["L1"],"remove":["INBOX"],"reason":"Receipts, per the filing rule."}"#,
            store: reasoned.store, outbox: reasoned.outbox)

        #expect(plainResult.isError == false)
        #expect(reasonedResult.isError == false)
        let plainMutations = queuedMutations(plain.outbox)
        let reasonedMutations = queuedMutations(reasoned.outbox)
        #expect(plainMutations.count == 1)
        #expect(reasonedMutations.count == 1)
        // Identical, field for field — thread ids, adds and removes.
        #expect(reasonedMutations == plainMutations)
        // And the local application matches too: same stored labels on both.
        #expect(reasoned.store.thread("t1")?.messages.first?.labelIDs
                == plain.store.thread("t1")?.messages.first?.labelIDs)
        #expect(reasoned.store.thread("t1")?.messages.first?.labelIDs == ["L1"])
        // The one difference is the record — which the plain tool does not write.
        #expect(reasoned.store.labelReasons(accountID: "a1", threadID: "t1").count == 1)
        #expect(plain.store.labelReasons(accountID: "a1", threadID: "t1").isEmpty)
    }

    @Test("label_with_reason writes the store, then the outbox, before it returns")
    func labelWithReasonIsLocalFirstInThatOrder() async throws {
        let fixture = try reasonFixture()
        let documents = fixture.documents

        let result = await RavenMCPOperations.run(
            "label_with_reason",
            arguments: #"{"thread_ids":["t1"],"add":["L1"],"reason":"Filed."}"#,
            store: fixture.store, outbox: fixture.outbox)

        #expect(result.isError == false)
        // Both effects are already visible to the caller of this one await —
        // nothing is deferred to a later drain or a later frame.
        #expect(fixture.store.thread("t1")?.messages.first?.labelIDs == ["INBOX", "L1"])
        #expect(queuedMutations(fixture.outbox).count == 1)
        #expect(fixture.store.labelReasons(accountID: "a1", threadID: "t1").count == 1)
        // Order, from the shared write log: the thread document is written
        // before the outbox document is. `#require` rather than `firstIndex!`
        // so a missing write fails this test instead of trapping the runner.
        let log = documents.writeLog
        let threadWrite = try #require(log.lastIndex(of: DocumentKeys.thread("t1")))
        let outboxWrite = try #require(log.lastIndex(of: DocumentKeys.outbox))
        #expect(threadWrite < outboxWrite)
    }

    @Test("an unknown thread id applies nothing to the rest of the batch")
    func labelWithReasonUnknownIDDoesNotPartiallyApply() async throws {
        let fixture = try reasonFixture()

        let result = await RavenMCPOperations.run(
            "label_with_reason",
            arguments: #"{"thread_ids":["t1","t-missing","t2"],"add":["L1"],"reason":"Filed."}"#,
            store: fixture.store, outbox: fixture.outbox)

        #expect(result.isError)
        #expect(result.text.contains("t-missing"))
        // Nothing applied to the ids that DID exist, nothing queued, nothing
        // recorded — the three ways a partial application would show up.
        #expect(fixture.store.thread("t1")?.messages.first?.labelIDs == ["INBOX"])
        #expect(fixture.store.thread("t2")?.messages.first?.labelIDs == ["INBOX"])
        #expect(fixture.outbox.pending().isEmpty)
        #expect(fixture.store.labelReasons(accountID: "a1", threadID: nil).isEmpty)
    }

    @Test("a blank or over-long reason is refused at the boundary with nothing applied")
    func labelWithReasonValidatesAtTheBoundary() async throws {
        let fixture = try reasonFixture()
        let overCap = String(repeating: "r", count: LabelReason.maxReasonLength + 1)

        let blank = await RavenMCPOperations.run(
            "label_with_reason", arguments: #"{"thread_ids":["t1"],"add":["L1"],"reason":"   "}"#,
            store: fixture.store, outbox: fixture.outbox)
        let missing = await RavenMCPOperations.run(
            "label_with_reason", arguments: #"{"thread_ids":["t1"],"add":["L1"]}"#,
            store: fixture.store, outbox: fixture.outbox)
        let tooLong = await RavenMCPOperations.run(
            "label_with_reason",
            arguments: #"{"thread_ids":["t1"],"add":["L1"],"reason":"\#(overCap)"}"#,
            store: fixture.store, outbox: fixture.outbox)

        #expect(blank.isError)
        #expect(missing.isError)
        #expect(tooLong.isError)
        #expect(fixture.store.thread("t1")?.messages.first?.labelIDs == ["INBOX"])
        #expect(fixture.outbox.pending().isEmpty)
        #expect(fixture.store.labelReasons(accountID: "a1", threadID: nil).isEmpty)
        // One character shorter is accepted, so the refusals above are the CAP
        // and not a tool that rejects every reason.
        let atCap = String(repeating: "r", count: LabelReason.maxReasonLength)
        let accepted = await RavenMCPOperations.run(
            "label_with_reason",
            arguments: #"{"thread_ids":["t1"],"add":["L1"],"reason":"\#(atCap)"}"#,
            store: fixture.store, outbox: fixture.outbox)
        #expect(accepted.isError == false)
        #expect(fixture.store.labelReasons(accountID: "a1", threadID: "t1").count == 1)
    }

    /// The reason is local-only, and the assertion has to survive someone
    /// smuggling it into any field of the mutation — not just `add`. So the
    /// applied mutation is compared to the plain `label` tool's AND its whole
    /// encoded form is searched for the sentinel, with the sentinel proven
    /// findable in the local record first (otherwise a search that finds
    /// nothing proves nothing).
    @Test("the reason never leaves the machine: no provider mutation carries it")
    func reasonNeverReachesTheProvider() async throws {
        let sentinel = "SENTINEL-REASON-Z9-do-not-transmit"
        let reasoned = try reasonFixture()
        let plain = try reasonFixture()

        let result = await RavenMCPOperations.run(
            "label_with_reason",
            arguments: #"{"thread_ids":["t1","t2"],"add":["L1"],"reason":"\#(sentinel)"}"#,
            store: reasoned.store, outbox: reasoned.outbox)
        _ = await RavenMCPOperations.run(
            "label", arguments: #"{"thread_ids":["t1","t2"],"add":["L1"]}"#,
            store: plain.store, outbox: plain.outbox)
        #expect(result.isError == false)
        // The sentinel IS in the local record — the search below is therefore
        // looking for something that exists somewhere.
        #expect(reasoned.store.labelReasons(accountID: "a1", threadID: "t1")
            .map(\.reason) == [sentinel])

        await reasoned.outbox.drain()
        await plain.outbox.drain()

        #expect(reasoned.provider.appliedMutations.count == 1)
        #expect(plain.provider.appliedMutations.count == 1)
        #expect(reasoned.provider.appliedMutations == plain.provider.appliedMutations)
        let encoder = JSONEncoder()
        for mutation in reasoned.provider.appliedMutations {
            let json = try #require(String(data: try encoder.encode(mutation), encoding: .utf8))
            #expect(json.contains(sentinel) == false, "the reason reached the provider: \(json)")
        }
        #expect(reasoned.provider.sentMessages.isEmpty)
    }

}
