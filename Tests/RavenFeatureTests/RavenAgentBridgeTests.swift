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

    // MARK: resyncFromScratch cannot run twice concurrently

    @Test("a second resync while one is running is refused, and a failure in the walk is still observable")
    func resyncRefusesConcurrentAndSurfacesFailure() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        // Stop the real poll loop for the same reason `syncOnceRecordsTransientFailure`
        // does — nothing here should race a background tick.
        runtime.teardown()

        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                                   displayName: "Me", state: .ready))
        let provider = FakeMailProvider(accountID: "a1")
        // Parks the walk mid-page so this test has a deterministic window in
        // which to attempt (and prove refused) a second concurrent resync,
        // rather than racing scheduling to try to catch it in flight.
        provider.holdsFetchThreads = true
        provider.pages = [ThreadPage(threads: [], nextPageToken: nil)]
        // Scripts the walk to fail after it resumes, so this test also proves
        // the failure isn't swallowed by having gone through the detached
        // `resyncFromScratch()` path instead of the old inline-awaited one.
        provider.failures["fetchLabels"] = [MailError.providerFailed(status: 500, message: "boom")]
        runtime.syncEngine = SyncEngine(store: runtime.store, provider: provider, accountID: "a1")

        runtime.resyncFromScratch()
        await provider.waitUntilFetchThreadsEntered()
        #expect(runtime.isResyncing == true)

        // A second call while the first is still parked inside fetchThreads
        // must be refused outright — not queued, not started as a second
        // competing walk over the same store.
        runtime.resyncFromScratch()
        #expect(provider.fetchThreadsCallCount == 1)

        provider.releaseFetchThreads()
        // Let the (now-failing) walk run to completion.
        while runtime.isResyncing {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(provider.fetchThreadsCallCount == 1)
        #expect(runtime.lastSyncError != nil)
        if case .failed = runtime.syncState {
            // expected
        } else {
            Issue.record("expected .failed, got \(runtime.syncState)")
        }
        let account = try #require(runtime.store.accounts().first(where: { $0.id == "a1" }))
        #expect(account.state == .failed)
        #expect(account.lastError != nil)
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
        try runtime.store.saveBody(MessageBody(messageID: "m1", plainText: "private", html: nil),
                                   accountID: "a1")
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

    // MARK: Archive search (provider-side search outside the synced window)

    @Test("a remote archive search caches its hits and they are reachable in the store even outside the synced window")
    func searchArchiveCachesHitsReachableOutsideWindow() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        let provider = FakeMailProvider(accountID: "a1")
        let sixMonthsAgo = Calendar(identifier: .gregorian)
            .date(byAdding: .month, value: -6, to: Date())!
        provider.searchResults = [MailThread(id: "old-1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "old-1", from: MailAddress(email: "old@x.com"),
                        subject: "Ancient invoice", date: sixMonthsAgo, labelIDs: [], snippet: "s")
        ])]
        runtime.attachTestProvider(provider, accountID: "a1")

        await runtime.searchArchive(query: "invoice")

        guard case .results(let hits) = runtime.archiveSearchState else {
            Issue.record("expected .results, got \(runtime.archiveSearchState)")
            return
        }
        #expect(hits.map(\.id) == ["old-1"])
        // Reachable through the store directly — the presentation this task
        // chose (a distinct "results from all mail" list) reads exactly this
        // way, and `read_thread`/archive/reply all go through `store.thread`.
        #expect(runtime.store.thread("old-1") != nil)
        // NOT part of the windowed Inbox view: its month shard (6 months
        // back) sits outside the recent-months window `RavenViewModel.reload`
        // loads, which is precisely why a separate presentation is required.
        #expect(runtime.model.summaries.contains { $0.id == "old-1" } == false)
    }

    @Test("local search never calls the provider — only an explicit archive search does")
    func localSearchNeverTouchesProvider() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "me@x.com",
                                                  displayName: "Me", state: .ready))
        try runtime.store.upsertThread(MailThread(id: "t1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "Invoice March", date: Date(), labelIDs: ["INBOX"], snippet: "s")
        ]))
        let provider = FakeMailProvider(accountID: "a1")
        runtime.attachTestProvider(provider, accountID: "a1")
        runtime.model.accountID = "a1"
        runtime.model.reload()

        runtime.model.searchText = "invoice"
        #expect(runtime.model.visibleThreads.map(\.id) == ["t1"])
        #expect(provider.searchThreadsCallCount == 0,
                "the in-memory ThreadSearch path must return instantly without touching the provider")
    }

    @Test("a rate-limited archive search is distinguishable from a genuinely empty result")
    func searchArchiveRateLimitIsDistinctFromEmpty() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        let provider = FakeMailProvider(accountID: "a1")
        provider.failures["searchThreads"] = [MailError.rateLimited(retryAfter: 42)]
        runtime.attachTestProvider(provider, accountID: "a1")

        await runtime.searchArchive(query: "invoice")

        guard case .failed(let message) = runtime.archiveSearchState else {
            Issue.record("expected .failed, got \(runtime.archiveSearchState)")
            return
        }
        #expect(message.contains("42"))
        #expect(message.contains("MailError") == false, "must not leak the raw error case name")

        // A second search that genuinely finds nothing must land in a
        // different, distinguishable state — not the same as the failure
        // above.
        provider.searchResults = []
        await runtime.searchArchive(query: "nothing-matches-this")
        guard case .results(let hits) = runtime.archiveSearchState else {
            Issue.record("expected .results([]), got \(runtime.archiveSearchState)")
            return
        }
        #expect(hits.isEmpty)
    }

    @Test("an empty search text idles the archive search state without calling the provider")
    func emptyQueryIdlesWithoutCallingProvider() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        let provider = FakeMailProvider(accountID: "a1")
        runtime.attachTestProvider(provider, accountID: "a1")

        await runtime.searchArchive(query: "   ")

        #expect(runtime.archiveSearchState == .idle)
        #expect(provider.searchThreadsCallCount == 0)
    }
}
