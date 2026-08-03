import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// The M1 foundation: several accounts synced, read, mutated, sent from and
/// signed out of independently. Each test here pins one property that a
/// single-account codebase could not have had.
@Suite("Multi-account foundation")
@MainActor struct MultiAccountTests {

    private func thread(_ id: String, account: String, subject: String, date: Date,
                        unread: Bool = false) -> MailThread {
        MailThread(id: id, accountID: account, messages: [
            MailMessage(id: "m-\(id)", threadID: id, from: MailAddress(email: "s@x.com"),
                        subject: subject, date: date, isRead: !unread,
                        labelIDs: unread ? ["INBOX", "UNREAD"] : ["INBOX"], snippet: "s")
        ])
    }

    private func store(accounts: [String]) throws -> DocumentMailStore {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        for id in accounts {
            try store.saveAccount(MailAccount(id: id, provider: .gmail, address: "\(id)@x.com",
                                              displayName: id, state: .ready))
        }
        return store
    }

    // MARK: Per-account sync

    @Test("two accounts sync independently, and one failing does not stall the other")
    func twoAccountsSyncIndependently() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        // Stop the real poll loop so it cannot race this test's manual tick.
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a1@x.com",
                                                  displayName: "A1", syncCursor: "c-a1",
                                                  state: .ready))
        try runtime.store.saveAccount(MailAccount(id: "a2", provider: .gmail, address: "a2@x.com",
                                                  displayName: "A2", syncCursor: "c-a2",
                                                  state: .ready))
        try runtime.store.upsertThread(thread("t1", account: "a1", subject: "one", date: Date()))
        try runtime.store.upsertThread(thread("t2", account: "a2", subject: "two", date: Date()))

        // a1's delta fails transiently on the thread fetch: the cursor must be
        // held, the failure recorded against a1 — and a2 must still sync.
        let p1 = FakeMailProvider(accountID: "a1")
        p1.deltas = [MailDelta(changedThreadIDs: ["t1"], removedThreadIDs: [], newCursor: "c-a1-next")]
        p1.failures["fetchThread"] = [MailError.providerFailed(status: 500, message: "boom")]
        let p2 = FakeMailProvider(accountID: "a2")
        p2.threadsByID["t2"] = thread("t2", account: "a2", subject: "two updated", date: Date())
        p2.deltas = [MailDelta(changedThreadIDs: ["t2"], removedThreadIDs: [], newCursor: "c-a2-next")]

        runtime.syncEngines["a1"] = SyncEngine(store: runtime.store, provider: p1, accountID: "a1")
        runtime.syncEngines["a2"] = SyncEngine(store: runtime.store, provider: p2, accountID: "a2")

        await runtime.syncOnce()

        // a1: failed, cursor held (see SyncEngine.syncDelta) — its failure is
        // observable as a1's, not as a single app-wide status.
        if case .failed = runtime.syncState(for: "a1") {} else {
            Issue.record("expected a1 .failed, got \(runtime.syncState(for: "a1"))")
        }
        #expect(runtime.lastSyncError(for: "a1") != nil)
        #expect(runtime.store.accounts().first { $0.id == "a1" }?.syncCursor == "c-a1",
                "a transient failure must not advance the cursor")

        // a2: unaffected — the failing account did not stall it.
        #expect(runtime.syncState(for: "a2") == .idle)
        #expect(runtime.lastSyncError(for: "a2") == nil)
        #expect(runtime.store.accounts().first { $0.id == "a2" }?.syncCursor == "c-a2-next")
        #expect(runtime.store.thread("t2")?.subject == "two updated")
    }

    @Test("one poll loop services every account — no timer per account")
    func oneTimerForEveryAccount() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        // Cancel the real loop first, synchronously, so the tick asserted below
        // is unambiguously this test's own — same reason the sync tests do it.
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a1@x.com",
                                                  displayName: "A1", syncCursor: "c1", state: .ready))
        try runtime.store.saveAccount(MailAccount(id: "a2", provider: .gmail, address: "a2@x.com",
                                                  displayName: "A2", syncCursor: "c2", state: .ready))
        let p1 = FakeMailProvider(accountID: "a1")
        let p2 = FakeMailProvider(accountID: "a2")
        runtime.syncEngines["a1"] = SyncEngine(store: runtime.store, provider: p1, accountID: "a1")
        runtime.syncEngines["a2"] = SyncEngine(store: runtime.store, provider: p2, accountID: "a2")

        // A SINGLE tick of the one shared loop advances both accounts.
        await runtime.syncOnce()

        #expect(runtime.store.accounts().first { $0.id == "a1" }?.lastSyncedAt != nil)
        #expect(runtime.store.accounts().first { $0.id == "a2" }?.lastSyncedAt != nil)
    }

    // MARK: The merged read

    @Test("a merged read returns rows from both accounts, date-ordered and attributed")
    func mergedReadIsOrderedAndAttributed() throws {
        let store = try store(accounts: ["a1", "a2"])
        let now = Date()
        try store.upsertThread(thread("a1-old", account: "a1", subject: "oldest",
                                      date: now.addingTimeInterval(-7200)))
        try store.upsertThread(thread("a2-mid", account: "a2", subject: "middle",
                                      date: now.addingTimeInterval(-3600)))
        try store.upsertThread(thread("a1-new", account: "a1", subject: "newest", date: now))

        let rows = UnifiedInbox.inbox(store: store, months: UnifiedInbox.recentMonths())

        #expect(rows.map(\.id) == ["a1-new", "a2-mid", "a1-old"],
                "the merge must interleave accounts by date, not block them by account")
        #expect(rows.map(\.accountID) == ["a1", "a2", "a1"],
                "every row must still say which account it came from")

        // Scoped to one account, the same call answers only for that account.
        let onlyA2 = UnifiedInbox.inbox(store: store, accountIDs: ["a2"],
                                        months: UnifiedInbox.recentMonths())
        #expect(onlyA2.map(\.id) == ["a2-mid"])
    }

    @Test("the view model's unified list covers every account and shares the merge")
    func viewModelUnifiedList() throws {
        let store = try store(accounts: ["a1", "a2"])
        let now = Date()
        try store.upsertThread(thread("t-a1", account: "a1", subject: "one", date: now))
        try store.upsertThread(thread("t-a2", account: "a2", subject: "two",
                                      date: now.addingTimeInterval(-60)))
        let model = RavenViewModel(store: store)

        model.reload()
        #expect(model.summaries.map(\.id) == ["t-a1", "t-a2"],
                "no account filter must mean ALL accounts, not accounts.first")

        model.accountID = "a2"
        model.reload()
        #expect(model.summaries.map(\.id) == ["t-a2"])
    }

    // MARK: Send routing

    @Test("a send composed on account A transmits through A's provider even when B is first")
    func sendRoutesToTheComposingAccount() async throws {
        let router = MailProviderRouter()
        // B is attached FIRST and sorts first, so anything that reached for "the
        // first account" would transmit from B.
        let b = FakeMailProvider(accountID: "a-b")
        let a = FakeMailProvider(accountID: "a-c")
        router.attach(b, accountID: "a-b")
        router.attach(a, accountID: "a-c")
        #expect(router.attachedAccountIDs.first == "a-b")

        let outbox = Outbox(documents: InMemoryDocumentStore(), router: router, accountID: "a-b")
        let composed = OutgoingMessage(to: [MailAddress(email: "x@x.com")], subject: "hi",
                                       bodyText: "there", accountID: "a-c")
        let entryID = try outbox.enqueue(.send(composed))

        await outbox.drain()

        #expect(a.sentMessages.count == 1, "the composing account must transmit its own mail")
        #expect(b.sentMessages.isEmpty, "the default/first account must not transmit A's mail")
        #expect(outbox.outcome(for: entryID) == .sent)
    }

    @Test("a mutation is routed by the thread's account, not by a default")
    func mutationRoutesByThreadAccount() async throws {
        let store = try store(accounts: ["a1", "a2"])
        try store.upsertThread(thread("t-a2", account: "a2", subject: "two", date: Date()))
        let router = MailProviderRouter()
        let p1 = FakeMailProvider(accountID: "a1")
        let p2 = FakeMailProvider(accountID: "a2")
        router.attach(p1, accountID: "a1")
        router.attach(p2, accountID: "a2")
        // The outbox's default stamp is a1 — the wrong account for this thread.
        let outbox = Outbox(documents: InMemoryDocumentStore(), router: router, accountID: "a1")

        let result = await RavenMCPOperations.run("archive", arguments: #"{"thread_ids":["t-a2"]}"#,
                                                 store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(outbox.pending().first?.accountID == "a2",
                "the entry must be stamped from the thread, not from the outbox default")

        await outbox.drain()
        #expect(p2.appliedMutations.count == 1)
        #expect(p1.appliedMutations.isEmpty, "a2's thread must not be mutated through a1")
    }

    @Test("ids spanning two accounts queue one entry per account")
    func mutationSpanningAccountsSplits() async throws {
        let store = try store(accounts: ["a1", "a2"])
        try store.upsertThread(thread("t1", account: "a1", subject: "one", date: Date()))
        try store.upsertThread(thread("t2", account: "a2", subject: "two", date: Date()))
        let router = MailProviderRouter()
        let p1 = FakeMailProvider(accountID: "a1")
        let p2 = FakeMailProvider(accountID: "a2")
        router.attach(p1, accountID: "a1")
        router.attach(p2, accountID: "a2")
        let outbox = Outbox(documents: InMemoryDocumentStore(), router: router)

        let result = await RavenMCPOperations.run("star", arguments: #"{"thread_ids":["t1","t2"]}"#,
                                                 store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(outbox.pending().count == 2)

        await outbox.drain()
        #expect(p1.appliedMutations.map(\.threadIDs) == [["t1"]])
        #expect(p2.appliedMutations.map(\.threadIDs) == [["t2"]])
    }

    @Test("the signature applied is the composing account's, not the outbox default's")
    func signatureFollowsTheComposingAccount() async throws {
        let store = try store(accounts: ["a1", "a2"])
        var a2 = try #require(store.accounts().first { $0.id == "a2" })
        a2.signature = "— from a2"
        try store.saveAccount(a2)
        var a1 = try #require(store.accounts().first { $0.id == "a1" })
        a1.signature = "— from a1"
        try store.saveAccount(a1)

        let router = MailProviderRouter()
        let p2 = FakeMailProvider(accountID: "a2")
        router.attach(FakeMailProvider(accountID: "a1"), accountID: "a1")
        router.attach(p2, accountID: "a2")
        let outbox = Outbox(documents: InMemoryDocumentStore(), router: router, accountID: "a1")

        let message = OutgoingMessage(to: [MailAddress(email: "x@x.com")], subject: "s",
                                      bodyText: "body", accountID: "a2")
        let result = try await SendAttempt.send(message, draftID: nil, outbox: outbox,
                                               store: store, drain: outbox.drain)
        #expect(result.isSent)
        let sent = try #require(p2.sentMessages.first)
        #expect(sent.bodyText.contains("— from a2"))
        #expect(sent.bodyText.contains("— from a1") == false)
    }

    // MARK: Sign-out is surgical

    @Test("signing out of one account leaves the other's mail, labels and queued sends intact")
    func signOutIsSurgical() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a1@x.com",
                                                  displayName: "A1", state: .ready))
        try runtime.store.saveAccount(MailAccount(id: "a2", provider: .gmail, address: "a2@x.com",
                                                  displayName: "A2", state: .ready))
        try runtime.store.upsertThread(thread("t1", account: "a1", subject: "one", date: Date()))
        try runtime.store.upsertThread(thread("t2", account: "a2", subject: "two", date: Date()))
        try runtime.store.saveBody(MessageBody(messageID: "m-t1", plainText: "a1 private",
                                               html: nil), accountID: "a1")
        try runtime.store.saveBody(MessageBody(messageID: "m-t2", plainText: "a2 private",
                                               html: nil), accountID: "a2")
        try runtime.store.saveLabels([MailLabel(id: "L1", name: "a1 label", kind: .user)],
                                     accountID: "a1")
        try runtime.store.saveLabels([MailLabel(id: "L2", name: "a2 label", kind: .user)],
                                     accountID: "a2")
        let p1 = FakeMailProvider(accountID: "a1")
        let p2 = FakeMailProvider(accountID: "a2")
        runtime.attachTestProvider(p1, accountID: "a1")
        runtime.attachTestProvider(p2, accountID: "a2")
        runtime.syncEngines["a1"] = SyncEngine(store: runtime.store, provider: p1, accountID: "a1")
        runtime.syncEngines["a2"] = SyncEngine(store: runtime.store, provider: p2, accountID: "a2")
        let keptSend = try runtime.outbox.enqueue(.send(
            OutgoingMessage(to: [MailAddress(email: "x@x.com")], subject: "keep",
                            bodyText: "b", accountID: "a2")))
        try runtime.outbox.enqueue(.send(
            OutgoingMessage(to: [MailAddress(email: "x@x.com")], subject: "drop",
                            bodyText: "b", accountID: "a1")))

        runtime.signOut("a1")

        // a1 is gone, completely.
        #expect(runtime.store.accounts().map(\.id) == ["a2"])
        #expect(runtime.store.thread("t1") == nil)
        #expect(runtime.store.body(messageID: "m-t1") == nil)
        #expect(runtime.store.labels(accountID: "a1").isEmpty)
        #expect(host.documents.data(forKey: DocumentKeys.thread("t1")) == nil)

        // a2 is entirely untouched — this is the assertion that would catch a
        // sign-out that purged more than it was asked to.
        #expect(runtime.store.thread("t2") != nil)
        #expect(runtime.store.body(messageID: "m-t2")?.plainText == "a2 private")
        #expect(runtime.store.labels(accountID: "a2").map(\.id) == ["L2"])
        #expect(runtime.outbox.pending().map(\.id) == [keptSend])
        #expect(runtime.syncEngines["a2"] != nil, "a2 must still be syncing")
        #expect(runtime.providers.provider(for: "a2") != nil)
        #expect(runtime.providers.provider(for: "a1") == nil)

        // And a2's queued send still transmits, through a2.
        await runtime.drainOutbox()
        #expect(p2.sentMessages.map(\.subject) == ["keep"])
        #expect(p1.sentMessages.isEmpty)
    }

    // MARK: MCP account awareness

    @Test("MCP reads with no account_id cover every account")
    func mcpReadsCoverAllAccounts() async throws {
        let store = try store(accounts: ["a1", "a2"])
        let now = Date()
        try store.upsertThread(thread("t-a1", account: "a1", subject: "invoice one",
                                      date: now, unread: true))
        try store.upsertThread(thread("t-a2", account: "a2", subject: "invoice two",
                                      date: now.addingTimeInterval(-60), unread: true))
        try store.saveLabels([MailLabel(id: "L1", name: "one", kind: .user)], accountID: "a1")
        try store.saveLabels([MailLabel(id: "L2", name: "two", kind: .user)], accountID: "a2")
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let unread = await RavenMCPOperations.run("unread_summary", arguments: "{}",
                                                  store: store, outbox: outbox)
        #expect(unread.isError == false)
        #expect(unread.text.contains("t-a1"))
        #expect(unread.text.contains("t-a2"), "'what's unread' must mean every account")
        #expect(unread.text.contains("2 unread threads"))

        let search = await RavenMCPOperations.run("search_mail", arguments: #"{"query":"invoice"}"#,
                                                 store: store, outbox: outbox)
        #expect(search.text.contains("t-a1"))
        #expect(search.text.contains("t-a2"))
        // Each row is attributed, so the agent can tell the mailboxes apart.
        #expect(search.text.contains("a1"))
        #expect(search.text.contains("a2"))

        let labels = await RavenMCPOperations.run("list_labels", arguments: "{}",
                                                 store: store, outbox: outbox)
        #expect(labels.text.contains("L1"))
        #expect(labels.text.contains("L2"))

        // And a scoped read still answers for exactly one account.
        let scoped = await RavenMCPOperations.run("unread_summary",
                                                 arguments: #"{"account_id":"a2"}"#,
                                                 store: store, outbox: outbox)
        #expect(scoped.text.contains("t-a2"))
        #expect(scoped.text.contains("t-a1") == false)
    }

    @Test("read_thread names the account so a reply can go out from the right address")
    func readThreadNamesTheAccount() async throws {
        let store = try store(accounts: ["a1", "a2"])
        try store.upsertThread(thread("t-a2", account: "a2", subject: "two", date: Date()))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run("read_thread",
                                                 arguments: #"{"thread_id":"t-a2"}"#,
                                                 store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("Account: a2"))
    }

    @Test("create_draft binds the draft to an account and refuses to guess between two")
    func createDraftResolvesAccount() async throws {
        let store = try store(accounts: ["a1", "a2"])
        try store.upsertThread(thread("t-a2", account: "a2", subject: "two", date: Date()))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        // Ambiguous: two accounts, no thread, no account_id.
        let refused = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"]}"#, store: store, outbox: outbox)
        #expect(refused.isError)
        #expect(refused.text.contains("account_id"))

        // Explicit.
        let explicit = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"],"account_id":"a1"}"#,
            store: store, outbox: outbox)
        #expect(explicit.isError == false)

        // Resolved from the thread being replied to.
        let inThread = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"],"thread_id":"t-a2"}"#,
            store: store, outbox: outbox)
        #expect(inThread.isError == false)
        let accounts = Set(DraftBox.shared.all().map { $0.message.accountID })
        #expect(accounts.contains("a1"))
        #expect(accounts.contains("a2"))
        for entry in DraftBox.shared.all() { DraftBox.shared.remove(entry.id) }
    }

    @Test("an unknown account_id on create_draft is refused rather than silently defaulted")
    func createDraftUnknownAccountRefused() async throws {
        let store = try store(accounts: ["a1"])
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        let result = await RavenMCPOperations.run(
            "create_draft", arguments: #"{"to":["x@x.com"],"account_id":"nope"}"#,
            store: store, outbox: outbox)
        #expect(result.isError)
    }

    // MARK: Agent context

    @Test("the context snapshot says which account the selected thread belongs to")
    func snapshotNamesTheAccount() throws {
        let store = try store(accounts: ["a1", "a2"])
        try store.upsertThread(thread("t-a2", account: "a2", subject: "Invoice", date: Date()))
        let model = RavenViewModel(store: store)
        model.select("t-a2")

        let snapshot = try #require(RavenAgentBridge.snapshot(model: model))
        // Sage cannot reply from the right address without knowing the account.
        #expect(snapshot.text.contains("a2@x.com"))
        #expect(snapshot.text.contains("a2"))
    }

    // MARK: Archive search across accounts

    @Test("an archive search with no account fans out over every account and merges by date")
    func archiveSearchFansOut() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a1@x.com",
                                                  displayName: "A1", state: .ready))
        try runtime.store.saveAccount(MailAccount(id: "a2", provider: .gmail, address: "a2@x.com",
                                                  displayName: "A2", state: .ready))
        let now = Date()
        let p1 = FakeMailProvider(accountID: "a1")
        p1.searchResults = [thread("old-a1", account: "a1", subject: "invoice",
                                   date: now.addingTimeInterval(-3600))]
        let p2 = FakeMailProvider(accountID: "a2")
        p2.searchResults = [thread("old-a2", account: "a2", subject: "invoice", date: now)]
        runtime.attachTestProvider(p1, accountID: "a1")
        runtime.attachTestProvider(p2, accountID: "a2")

        await runtime.searchArchive(query: "invoice")

        guard case .results(let hits) = runtime.archiveSearchState else {
            Issue.record("expected .results, got \(runtime.archiveSearchState)")
            return
        }
        #expect(hits.map(\.id) == ["old-a2", "old-a1"], "merged newest-first across accounts")
        #expect(runtime.store.thread("old-a1") != nil)
        #expect(runtime.store.thread("old-a2") != nil)
    }

    @Test("one account failing an archive search does not discard the other's real hits")
    func archiveSearchPartialFailureKeepsHits() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        let p1 = FakeMailProvider(accountID: "a1")
        p1.failures["searchThreads"] = [MailError.rateLimited(retryAfter: 30)]
        let p2 = FakeMailProvider(accountID: "a2")
        p2.searchResults = [thread("hit-a2", account: "a2", subject: "invoice", date: Date())]
        runtime.attachTestProvider(p1, accountID: "a1")
        runtime.attachTestProvider(p2, accountID: "a2")

        await runtime.searchArchive(query: "invoice")

        guard case .results(let hits) = runtime.archiveSearchState else {
            Issue.record("expected .results, got \(runtime.archiveSearchState)")
            return
        }
        #expect(hits.map(\.id) == ["hit-a2"])
    }

    // MARK: Router

    @Test("detaching one account leaves the others routable")
    func detachIsScoped() {
        let router = MailProviderRouter()
        router.attach(FakeMailProvider(accountID: "a1"), accountID: "a1")
        router.attach(FakeMailProvider(accountID: "a2"), accountID: "a2")
        router.detach(accountID: "a1")
        #expect(router.provider(for: "a1") == nil)
        #expect(router.provider(for: "a2") != nil)
        #expect(router.attachedAccountIDs == ["a2"])
    }

    @Test("an entry for an account with no attached provider stays queued rather than going out elsewhere")
    func unroutableEntryStaysQueued() async throws {
        let router = MailProviderRouter()
        let p1 = FakeMailProvider(accountID: "a1")
        router.attach(p1, accountID: "a1")
        let outbox = Outbox(documents: InMemoryDocumentStore(), router: router)
        let entry = try outbox.enqueue(.send(
            OutgoingMessage(to: [MailAddress(email: "x@x.com")], subject: "s", bodyText: "b",
                            accountID: "signed-out")))

        await outbox.drain()

        #expect(p1.sentMessages.isEmpty, "a1 must not transmit another account's mail")
        #expect(outbox.outcome(for: entry) == .queued(inFlight: false))
    }
}
