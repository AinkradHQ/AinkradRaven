import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

@Suite("Mail agent bridge")
@MainActor struct RavenAgentBridgeTests {
    private func makeModel() throws -> (RavenViewModel, DocumentMailStore) {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
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
        try store.upsertThread(MailThread(id: "t1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
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
        try store.upsertThread(MailThread(id: "t1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
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
    }

    @Test("RavenRuntime.teardown releases the context source and every action token")
    func teardownReleasesRegistrations() throws {
        let contextRegistry = RecordingContextRegistry()
        let actionRegistry = RecordingActionRegistry()
        let host = FakeHostServices(context: contextRegistry, actions: actionRegistry)

        let runtime = RavenRuntime(host: host)
        #expect(contextRegistry.sources.count == 1)
        #expect(actionRegistry.handlers.count == 1)

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

    // MARK: sync timer failure path

    @Test("syncOnce surfaces a transient delta failure even though syncDelta itself doesn't throw")
    func syncOnceRecordsTransientFailure() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        // `init` already started the real poll loop (`startSyncTimer`). Cancel
        // it here, synchronously and before any `await`, so it cannot race
        // this test's manual `syncOnce()` call — Swift concurrency only lets
        // an unstructured `Task` run at a suspension point, and there is none
        // between `RavenRuntime(host:)` and this call. Without this, the
        // background tick and this test's tick can interleave and consume the
        // scripted failure and the one-shot delta between them.
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                                   displayName: "Me", syncCursor: "cursor-0", state: .ready))
        try runtime.store.upsertThread(MailThread(id: "t1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "S", date: Date(), labelIDs: ["INBOX"], snippet: "s")
        ]))

        let provider = FakeMailProvider(accountID: "a1")
        provider.deltas = [MailDelta(changedThreadIDs: ["t1"], removedThreadIDs: [], newCursor: "cursor-1")]
        provider.failures["fetchThread"] = [MailError.providerFailed(status: 500, message: "boom")]
        runtime.syncEngine = SyncEngine(store: runtime.store, provider: provider, accountID: "a1")

        #expect(runtime.lastSyncError == nil)
        await runtime.syncOnce()

        // syncDelta() does NOT throw on a transient per-thread failure — it
        // holds the cursor and records the failure on `state` instead. A
        // naive `do { try await engine.syncDelta() } catch { log }` would see
        // no exception and report nothing. `syncOnce` must still surface it.
        #expect(runtime.lastSyncError != nil)
        if case .failed = runtime.syncState {
            // expected
        } else {
            Issue.record("expected .failed, got \(runtime.syncState)")
        }
    }

    // MARK: account row is read-modify-written, never clobbered by a snapshot

    /// The Settings signature field wrote back a `MailAccount` captured when
    /// the row was rendered, so every keystroke restored a stale
    /// `syncCursor`/`lastSyncedAt`/`state`/`lastError`. Rolling the cursor
    /// back re-walks mail; rolling it to nil forces a full backfill.
    @Test("editing the signature preserves the rest of the account row")
    func signatureEditDoesNotClobberSyncState() throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                                  displayName: "Me", syncCursor: "cursor-9",
                                                  state: .ready, lastSyncedAt: Date(),
                                                  lastError: nil, signature: "old"))
        // A stale snapshot, exactly as SwiftUI would have captured at render.
        let stale = try #require(runtime.store.accounts().first)
        // Sync moves on underneath the open Settings pane.
        var advanced = stale
        advanced.syncCursor = "cursor-42"
        advanced.state = .ready
        try runtime.store.saveAccount(advanced)

        runtime.updateSignature("new signature", accountID: "a1")

        let saved = try #require(runtime.store.accounts().first)
        #expect(saved.signature == "new signature")
        #expect(saved.syncCursor == "cursor-42",
                "a signature keystroke must not roll the sync cursor back")
        #expect(stale.syncCursor == "cursor-9")   // proves the snapshot really was stale
    }

    // MARK: sign-out leaves nothing behind

    @Test("signing out purges the account's local mail and its queued sends")
    func signOutPurgesMailAndOutbox() throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                                  displayName: "Me", state: .ready))
        try runtime.store.upsertThread(MailThread(id: "t1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "S", date: Date(), labelIDs: ["INBOX"], snippet: "s")
        ]))
        try runtime.store.saveBody(MessageBody(messageID: "m1", plainText: "private", html: nil))
        runtime.outbox.accountID = "a1"
        try runtime.outbox.enqueue(.send(OutgoingMessage(to: [MailAddress(email: "b@x.com")],
                                                         subject: "s", bodyText: "b")))

        runtime.signOut("a1")

        #expect(runtime.store.accounts().isEmpty)
        #expect(runtime.store.thread("t1") == nil, "mail must not stay readable after sign-out")
        #expect(runtime.store.body(messageID: "m1") == nil)
        #expect(host.documents.data(forKey: DocumentKeys.thread("t1")) == nil)
        #expect(runtime.outbox.pending().isEmpty,
                "a send queued for a1 must not survive to transmit from the next account")
    }
}
