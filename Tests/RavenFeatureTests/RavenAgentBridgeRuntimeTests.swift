import AinkradAppKit
import Foundation
import Testing

@testable import RavenFeature

/// The bridge driven through a live `RavenRuntime`: sync failure, resync,
/// account writes, sign-out and archive search. Split out of
/// `RavenAgentBridgeTests`.
@Suite("Mail agent bridge — runtime")
@MainActor struct RavenAgentBridgeRuntimeTests {
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
        try runtime.store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail, address: "me@x.com",
                displayName: "Me", syncCursor: "cursor-0", state: .ready))
        try runtime.store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
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

        try runtime.store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail, address: "me@x.com",
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
        try runtime.store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail, address: "me@x.com",
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
        #expect(
            saved.syncCursor == "cursor-42",
            "a signature keystroke must not roll the sync cursor back")
        #expect(stale.syncCursor == "cursor-9")  // proves the snapshot really was stale
    }

    // MARK: sign-out leaves nothing behind

    @Test("signing out purges the account's local mail and its queued sends")
    func signOutPurgesMailAndOutbox() throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        try runtime.store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail, address: "me@x.com",
                displayName: "Me", state: .ready))
        try runtime.store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "S", date: Date(), labelIDs: ["INBOX"], snippet: "s")
                ]))
        try runtime.store.saveBody(
            MessageBody(messageID: "m1", plainText: "private", html: nil),
            accountID: "a1")
        runtime.outbox.accountID = "a1"
        try runtime.outbox.enqueue(
            .send(
                OutgoingMessage(
                    to: [MailAddress(email: "b@x.com")],
                    subject: "s", bodyText: "b")))

        runtime.signOut("a1")

        #expect(runtime.store.accounts().isEmpty)
        #expect(runtime.store.thread("t1") == nil, "mail must not stay readable after sign-out")
        #expect(runtime.store.body(messageID: "m1") == nil)
        #expect(host.documents.data(forKey: DocumentKeys.thread("t1")) == nil)
        #expect(
            runtime.outbox.pending().isEmpty,
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
        provider.searchResults = [
            MailThread(
                id: "old-1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "old-1", from: MailAddress(email: "old@x.com"),
                        subject: "Ancient invoice", date: sixMonthsAgo, labelIDs: [], snippet: "s")
                ])
        ]
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
        try runtime.store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail, address: "me@x.com",
                displayName: "Me", state: .ready))
        try runtime.store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "Invoice March", date: Date(), labelIDs: ["INBOX"], snippet: "s")
                ]))
        let provider = FakeMailProvider(accountID: "a1")
        runtime.attachTestProvider(provider, accountID: "a1")
        runtime.model.accountID = "a1"
        runtime.model.reload()

        runtime.model.searchText = "invoice"
        #expect(runtime.model.visibleThreads.map(\.id) == ["t1"])
        #expect(
            provider.searchThreadsCallCount == 0,
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
