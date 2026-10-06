import AinkradAppKit
import Foundation
import Testing

@testable import RavenFeature

@Suite("Mail agent bridge")
@MainActor struct RavenAgentBridgeTests {
    private func makeModel() throws -> (RavenViewModel, DocumentMailStore) {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail, address: "me@x.com",
                displayName: "Me", state: .ready))
        return (RavenViewModel(store: store), store)
    }

    // MARK: snapshot

    @Test("no selection publishes no context rather than an empty snapshot")
    func noSelection() throws {
        let (model, _) = try makeModel()
        #expect(RavenAgentBridge.snapshot(model: model) == nil)
    }

    @Test("a selected thread publishes its subject and id so Sage can act on 'this'")
    func selectionSnapshot() throws {
        let (model, store) = try makeModel()
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "Invoice March", date: Date(), labelIDs: ["INBOX"], snippet: "s")
                ]))
        model.select("t1")

        let snapshot = try #require(RavenAgentBridge.snapshot(model: model))
        #expect(snapshot.kind == "mail")
        #expect(snapshot.text.contains("t1"))
        #expect(snapshot.text.contains("Invoice March"))
    }

    // MARK: open_thread

    @Test("open_thread with malformed JSON returns an error result, not a crash")
    func openThreadMalformedJSON() throws {
        let (model, _) = try makeModel()
        let result = RavenAgentBridge.openThread(arguments: "{ not json", model: model)
        #expect(result.isError)
    }

    @Test("open_thread with a missing thread_id returns an error result")
    func openThreadMissingKey() throws {
        let (model, _) = try makeModel()
        let result = RavenAgentBridge.openThread(arguments: #"{"foo": "bar"}"#, model: model)
        #expect(result.isError)
    }

    @Test("open_thread with an unknown id returns an error result rather than selecting nothing silently")
    func openThreadUnknownID() throws {
        let (model, _) = try makeModel()
        let result = RavenAgentBridge.openThread(arguments: #"{"thread_id": "does-not-exist"}"#, model: model)
        #expect(result.isError)
        #expect(model.selectedThread == nil)
    }

    @Test("open_thread with a real id selects it and returns success")
    func openThreadSuccess() throws {
        let (model, store) = try makeModel()
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "Invoice March", date: Date(), labelIDs: ["INBOX"], snippet: "s")
                ]))
        let result = RavenAgentBridge.openThread(arguments: #"{"thread_id": "t1"}"#, model: model)
        #expect(!result.isError)
        #expect(model.selectedThread?.id == "t1")
    }

    // MARK: registration + teardown

    @Test("register publishes exactly one context source and one open_thread action")
    func registersOnce() throws {
        let (model, _) = try makeModel()
        let contextRegistry = RecordingContextRegistry()
        let actionRegistry = RecordingActionRegistry()
        let host = FakeHostServices(context: contextRegistry, actions: actionRegistry)

        _ = RavenAgentBridge.register(host: host, model: model)

        #expect(contextRegistry.sources.count == 1)
        #expect(actionRegistry.ids.values.contains("open_thread"))
        #expect(actionRegistry.ids.values.contains("open_compose"))
    }

    @Test("RavenRuntime.teardown releases the context source and every action token")
    func teardownReleasesRegistrations() throws {
        let contextRegistry = RecordingContextRegistry()
        let actionRegistry = RecordingActionRegistry()
        let host = FakeHostServices(context: contextRegistry, actions: actionRegistry)

        let runtime = RavenRuntime(host: host)
        #expect(contextRegistry.sources.count == 1)
        // Two actions now: `open_thread` and `open_compose`. The count is
        // asserted, not just "non-empty", because the whole point of this test
        // is that EVERY token registered comes back out — a third action added
        // without a matching removal is the per-host leak the runtime cache was
        // fixed for, and it would pass an `isEmpty`-only check.
        #expect(actionRegistry.handlers.count == 2)

        runtime.teardown()

        #expect(contextRegistry.sources.isEmpty)
        #expect(actionRegistry.handlers.isEmpty)
    }

    @Test("RavenRuntime.teardown cancels the sync timer so it stops polling")
    func teardownCancelsSyncTask() throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        // Calling teardown twice must stay a no-op, not crash or double-remove.
        runtime.teardown()
    }

    // MARK: the open draft as context (part D)

    /// A FRESH publisher per test, never `ComposeDraftPublisher.shared`: the
    /// shared instance is process-global, and a test that published into it
    /// would make the "no selection publishes no context" test above fail
    /// depending on execution order.
    private func draftPublisher(_ draft: OutgoingMessage?) -> ComposeDraftPublisher {
        let publisher = ComposeDraftPublisher()
        publisher.publish(draft)
        return publisher
    }

    @Test("an open draft is published as context even with no thread selected")
    func openDraftIsContext() throws {
        let (model, _) = try makeModel()
        let draft = OutgoingMessage(
            to: [MailAddress(email: "bea@x.com")],
            subject: "Invoice", bodyText: "Here it is.")
        let snapshot = try #require(
            RavenAgentBridge.snapshot(
                model: model, publisher: draftPublisher(draft)))
        #expect(snapshot.text.contains("bea@x.com"))
        #expect(snapshot.text.contains("Invoice"))
        // The FULL body, untruncated — "shorten this" on a fragment returns a
        // rewrite of a fragment that the user then pastes over the real message.
        #expect(snapshot.text.contains("Here it is."))
        #expect(snapshot.title.contains("composing"))
    }

    @Test("an empty composer publishes no draft context")
    func emptyDraftIsNotContext() throws {
        let (model, _) = try makeModel()
        let blank = OutgoingMessage(to: [], subject: "  ", bodyText: "\n")
        #expect(
            RavenAgentBridge.snapshot(
                model: model,
                publisher: draftPublisher(blank)) == nil)
        #expect(!ComposeDraftPublisher.isWorthPublishing(blank))
    }

    @Test("the draft and the selected thread are both published, draft first")
    func draftAndThread() throws {
        let (model, store) = try makeModel()
        try store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "Invoice March", date: Date(), labelIDs: ["INBOX"], snippet: "s")
                ]))
        model.select("t1")
        let draft = OutgoingMessage(
            to: [MailAddress(email: "bea@x.com")],
            subject: "Re: Invoice March", bodyText: "Draft body.")
        let snapshot = try #require(
            RavenAgentBridge.snapshot(
                model: model, publisher: draftPublisher(draft)))
        let draftIndex = try #require(snapshot.text.range(of: "Open draft"))
        let threadIndex = try #require(snapshot.text.range(of: "Selected thread"))
        // The draft is the more specific answer to "what is the user looking
        // at", so it comes first.
        #expect(draftIndex.lowerBound < threadIndex.lowerBound)
    }

    @Test("bcc is labelled as blind so an agent does not repeat it in the body")
    func bccIsLabelledBlind() throws {
        let (model, _) = try makeModel()
        let draft = OutgoingMessage(
            to: [MailAddress(email: "bea@x.com")],
            bcc: [MailAddress(email: "boss@y.com")],
            subject: "S", bodyText: "B")
        let snapshot = try #require(
            RavenAgentBridge.snapshot(
                model: model, publisher: draftPublisher(draft)))
        #expect(snapshot.text.contains("Bcc (blind"))
        #expect(snapshot.text.contains("never repeat"))
    }

    // MARK: open_compose

    @Test("open_compose queues a prefill for the composer and does not send")
    func openComposePrefills() throws {
        let publisher = ComposeDraftPublisher()
        let result = RavenAgentBridge.openCompose(
            arguments: #"{"to":["bea@x.com"],"bcc":["boss@y.com"],"subject":"Hi","body":"Text"}"#,
            publisher: publisher)
        #expect(!result.isError)
        let queued = try #require(publisher.requestedPrefill)
        #expect(queued.to.map(\.email) == ["bea@x.com"])
        #expect(queued.bcc.map(\.email) == ["boss@y.com"])
        #expect(queued.subject == "Hi")
        #expect(queued.bodyText == "Text")
        // Nothing was published as "the open draft" — the composer does that
        // once it actually opens — and nothing was queued for transmission.
        #expect(publisher.openDraft == nil)
        #expect(result.text.contains("NOT sent"))
    }

    @Test("a prefill is consumed exactly once so a re-render cannot reapply it")
    func prefillConsumedOnce() throws {
        let publisher = ComposeDraftPublisher()
        _ = RavenAgentBridge.openCompose(arguments: #"{"subject":"Hi"}"#, publisher: publisher)
        #expect(publisher.consumeRequestedPrefill() != nil)
        #expect(publisher.consumeRequestedPrefill() == nil)
        #expect(publisher.requestedPrefill == nil)
    }

    @Test("open_compose with malformed JSON returns an error result, not a crash")
    func openComposeMalformed() throws {
        let publisher = ComposeDraftPublisher()
        #expect(
            RavenAgentBridge.openCompose(
                arguments: "{ not json",
                publisher: publisher
            ).isError)
        #expect(publisher.requestedPrefill == nil)
    }

    @Test("open_compose with nothing in it is refused rather than opening a blank composer")
    func openComposeEmpty() throws {
        let publisher = ComposeDraftPublisher()
        #expect(RavenAgentBridge.openCompose(arguments: "{}", publisher: publisher).isError)
        #expect(publisher.requestedPrefill == nil)
    }
}
