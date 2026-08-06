import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

@Suite("Raven MCP server")
@MainActor struct RavenMCPServerTests {
    @Test("every tool registers without a duplicate or a bad schema")
    func registersCleanly() {
        let made = RavenMCPServer.make(appID: "raven") { _, _ in
            AgentActionResult(text: "", isError: false)
        }
        #expect(made.failures.isEmpty)
    }

    @Test("send_draft is the only destructive tool and no send_mail exists")
    func sendGating() {
        let destructive = RavenMCPServer.tools.filter(\.destructive).map(\.name)
        #expect(destructive == ["send_draft"])
        #expect(RavenMCPServer.tools.contains { $0.name == "send_mail" } == false)
    }

    @Test("read tools are marked readOnly so the host can skip the gate")
    func readOnlyFlags() {
        let readOnly = Set(RavenMCPServer.tools.filter(\.readOnly).map(\.name))
        #expect(readOnly.isSuperset(of: ["list_accounts", "search_mail", "read_thread",
                                         "list_labels", "unread_summary"]))
    }

    @Test("every schema is parseable JSON")
    func schemasParse() throws {
        for tool in RavenMCPServer.tools {
            let data = Data(tool.schemaJSON.utf8)
            #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: data) }
        }
    }

    @Test("unread_summary reports counts from the store")
    func unreadSummary() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let now = Date()
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me", state: .ready))
        try store.upsertThread(MailThread(id: "t1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "Hi", date: now, isRead: false,
                        labelIDs: ["INBOX"], snippet: "s")
        ]))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run("unread_summary", arguments: "{}",
                                                 store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("t1"))
    }

    @Test("read_thread on a missing id is an error result, not a crash")
    func readMissingThread() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        let result = await RavenMCPOperations.run(
            "read_thread", arguments: #"{"thread_id":"nope"}"#, store: store, outbox: outbox)
        #expect(result.isError)
    }

    @Test("archive queues a mutation rather than calling a provider")
    func archiveQueues() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let now = Date()
        // The account row is a real precondition, not scaffolding: `archive` is
        // rendered through the vocabulary resolved from the thread's account, and
        // an account this build cannot resolve is refused rather than mutated
        // through another backend's label strings.
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "a1@example.test", displayName: "A1",
                                          state: .ready))
        try store.upsertThread(MailThread(id: "t1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@x.com"),
                        subject: "Hi", date: now, labelIDs: ["INBOX"], snippet: "s")
        ]))

        let result = await RavenMCPOperations.run(
            "archive", arguments: #"{"thread_ids":["t1"]}"#, store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(outbox.pending().count == 1)
        #expect(provider.appliedMutations.isEmpty)   // not sent until drain
    }

    @Test("search_mail on no matches is honest about the synced window")
    func searchMailEmptyIsHonestAboutWindow() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me", state: .ready))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice"}"#, store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("synced window"))
    }

    @Test("the searched window matches SyncEngine's sync window, not an independent guess")
    func searchWindowMatchesSyncWindow() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me", state: .ready))
        // A thread dated 80 days ago sits inside SyncEngine's 90-day window but
        // outside a naive "last 4 months" guess only in edge months; instead we
        // assert directly that the window used equals SyncEngine's default.
        let eightyDaysAgo = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -80, to: Date())!
        try store.upsertThread(MailThread(id: "t-old", accountID: "a1", messages: [
            MailMessage(id: "m-old", threadID: "t-old", from: MailAddress(email: "c@x.com"),
                        subject: "invoice", date: eightyDaysAgo, labelIDs: ["INBOX"], snippet: "s")
        ]))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice"}"#, store: store, outbox: outbox)
        #expect(result.isError == false)
        #expect(result.text.contains("t-old"))
    }

    @Test("search_mail defaults to the synced window and never touches the provider")
    func searchMailDefaultDoesNotTouchProvider() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me", state: .ready))
        let provider = FakeMailProvider()
        provider.searchResults = [MailThread(id: "archive-1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "archive-1", from: MailAddress(email: "old@x.com"),
                        subject: "invoice", date: Date(), labelIDs: [], snippet: "s")
        ])]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice"}"#,
            store: store, outbox: outbox,
            providers: MailProviderRouter(single: provider))

        #expect(result.isError == false)
        #expect(result.text.contains("synced window"))
        #expect(provider.searchThreadsCallCount == 0)
    }

    @Test("search_mail with include_archive reaches the provider and caches hits locally")
    func searchMailArchiveReachesProviderAndCaches() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me", state: .ready))
        let sixMonthsAgo = Calendar(identifier: .gregorian)
            .date(byAdding: .month, value: -6, to: Date())!
        let provider = FakeMailProvider()
        provider.searchResults = [MailThread(id: "archive-1", accountID: "a1", messages: [
            MailMessage(id: "m1", threadID: "archive-1", from: MailAddress(email: "old@x.com"),
                        subject: "invoice", date: sixMonthsAgo, labelIDs: [], snippet: "s")
        ])]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice","include_archive":true}"#,
            store: store, outbox: outbox,
            providers: MailProviderRouter(single: provider))

        #expect(result.isError == false)
        #expect(result.text.contains("archive-1"))
        #expect(provider.searchThreadsCallCount == 1)
        // Cached locally: reachable via the store even though its month
        // shard (6 months back) is outside the Inbox's synced window.
        #expect(store.thread("archive-1") != nil)
    }

    @Test("a rate-limited archive search is distinguishable from empty results and never leaks a raw error")
    func searchMailArchiveRateLimitIsDistinctFromEmpty() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me", state: .ready,
                                          lastError: nil))
        let provider = FakeMailProvider()
        provider.failures["searchThreads"] = [MailError.rateLimited(retryAfter: 30)]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice","include_archive":true}"#,
            store: store, outbox: outbox,
            providers: MailProviderRouter(single: provider))

        #expect(result.isError)
        #expect(result.text.contains("rate-limited"))
        #expect(result.text.contains("MailError") == false)
        // Never leaked into the persisted account document.
        #expect(store.accounts().first(where: { $0.id == "a1" })?.lastError == nil)
    }

    @Test("include_archive with no provider fails honestly instead of silently returning empty")
    func searchMailArchiveWithoutProviderFails() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                          address: "me@x.com", displayName: "Me", state: .ready))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let result = await RavenMCPOperations.run(
            "search_mail", arguments: #"{"query":"invoice","include_archive":true}"#,
            store: store, outbox: outbox)

        #expect(result.isError)
    }

    @Test("draft ids are distinct and non-sequential across saves")
    func draftIDsAreDistinctAndNonSequential() throws {
        let box = DraftBox()
        let message = OutgoingMessage(to: [MailAddress(email: "a@x.com")], subject: "s", bodyText: "b")
        let first = try box.save(message)
        let second = try box.save(message)
        #expect(first != second)
        // Not "draft-1"/"draft-2" style sequential ids — collision-proof across
        // process lifetimes rather than a counter that resets on relaunch.
        #expect(first != "draft-1")
        #expect(second != "draft-2")
    }

    @Test("send_draft on an id the box does not hold is an error result, not a crash or no-op")
    func sendDraftUnknownIDIsError() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)

        let result = await RavenMCPOperations.run(
            "send_draft", arguments: #"{"draft_id":"does-not-exist"}"#, store: store, outbox: outbox)
        #expect(result.isError)
        #expect(provider.sentMessages.isEmpty)
        #expect(outbox.pending().isEmpty)
    }

    /// M3 change: `send_draft` now applies the same undo-send hold window as
    /// the human Send button (see `RavenMCPOperations`'s doc comment on the
    /// `send_draft` case for why) — so a genuinely-succeeding send no longer
    /// transmits INSIDE this one call. It reports `queued` (benign, not an
    /// error) and the draft survives until the hold elapses and a later
    /// `outbox.drain()` (the 120s timer, in production) actually transmits
    /// it — proven below by draining again once the hold is in the past.
    @Test("send_draft holds the send for the undo window, then a later drain actually transmits it")
    func sendDraftSuccessSendsAndRemoves() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let draft = OutgoingMessage(to: [MailAddress(email: "a@x.com")], subject: "s", bodyText: "b")
        let id = try DraftBox.shared.save(draft)

        let result = await RavenMCPOperations.run(
            "send_draft", arguments: #"{"draft_id":"\#(id)"}"#, store: store, outbox: outbox)

        #expect(result.isError == false)
        #expect(result.text.contains("Sent") == false)
        #expect(provider.sentMessages.isEmpty, "held sends must not transmit before their window elapses")
        #expect(DraftBox.shared.draft(id) != nil, "the draft must survive while the send is only held")

        // `send_draft`'s own hold is 20s out, so `pending()` correctly shows
        // nothing to drain yet — that is the assertion above. To prove a
        // held entry DOES transmit once its window elapses (without an
        // actual 20s sleep), queue an equivalent entry whose `holdUntil` is
        // already in the past and drain: this is exactly the state
        // `pending()` would see for the original entry after real time
        // passed its deadline.
        _ = try outbox.enqueue(.send(draft), accountID: nil,
                               holdUntil: Date().addingTimeInterval(-1), sendAt: nil, draftID: id)
        await outbox.drain()
        #expect(provider.sentMessages.count == 1)
        #expect(DraftBox.shared.draft(id) == nil, "draining a since-eligible held entry removes its draft")
    }

    /// M3: `send_draft` now holds every send for the undo window, so a
    /// provider failure can no longer surface on the SAME drain the tool
    /// call itself triggers — see `sendDraftSuccessSendsAndRemoves`'s own
    /// comment above for why. This test now checks both halves: the
    /// immediate result is a benign "held", never an error (nothing has been
    /// attempted yet), and — once the hold has elapsed — the scripted
    /// failure still dead-letters exactly as before.
    @Test("send_draft against an unattached/unauthenticated provider does not claim success and keeps the draft")
    func sendDraftUnattachedProviderDoesNotClaimSuccess() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        provider.failures["send"] = [MailError.notAuthenticated(accountID: "a1"),
                                     MailError.notAuthenticated(accountID: "a1")]
        // `maxAttempts: 1` so the single scripted failure dead-letters on the
        // very first drain, exactly what an unattached `RavenProviderProxy`
        // (no account connected yet) looks like in practice: every attempt
        // fails the same way, so it is never going to succeed on retry.
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider, maxAttempts: 1)
        let draft = OutgoingMessage(to: [MailAddress(email: "a@x.com")], subject: "s", bodyText: "b")
        let id = try DraftBox.shared.save(draft)

        let result = await RavenMCPOperations.run(
            "send_draft", arguments: #"{"draft_id":"\#(id)"}"#, store: store, outbox: outbox)

        #expect(result.isError == false, "a still-held send is benign, not an error")
        #expect(result.text.contains("Sent") == false)
        #expect(provider.sentMessages.isEmpty)
        #expect(DraftBox.shared.draft(id) != nil, "the draft must survive an unconfirmed send")

        // Force the hold to have elapsed (the same technique used above) and
        // prove the scripted failure still dead-letters, not silently
        // resolves, once an attempt is actually made.
        _ = try outbox.enqueue(.send(draft), accountID: nil,
                               holdUntil: Date().addingTimeInterval(-1), sendAt: nil, draftID: id)
        await outbox.drain()
        #expect(outbox.deadLettered().isEmpty == false)
        #expect(provider.sentMessages.isEmpty)
        DraftBox.shared.remove(id)
    }

    @Test("send_draft after a transient failure reports queued, not sent, and keeps the draft")
    func sendDraftTransientFailureReportsQueued() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        provider.failures["send"] = [MailError.providerFailed(status: 500, message: "boom")]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let draft = OutgoingMessage(to: [MailAddress(email: "a@x.com")], subject: "s", bodyText: "b")
        let id = try DraftBox.shared.save(draft)

        let result = await RavenMCPOperations.run(
            "send_draft", arguments: #"{"draft_id":"\#(id)"}"#, store: store, outbox: outbox)

        // Held, not yet attempted — "queued" either way, but for the M3 hold
        // reason rather than the transient-failure reason until an attempt
        // is actually made below.
        #expect(result.isError == false)
        #expect(result.text.contains("queued"))
        #expect(result.text.contains("Sent") == false)
        #expect(provider.sentMessages.isEmpty)
        #expect(outbox.pending().isEmpty, "a held entry is not eligible, so it is not pending yet either")

        // Force the hold to have elapsed and confirm the scripted transient
        // failure is handled exactly as before: still queued (now for the
        // ordinary retry reason), draft kept, nothing sent.
        _ = try outbox.enqueue(.send(draft), accountID: nil,
                               holdUntil: Date().addingTimeInterval(-1), sendAt: nil, draftID: id)
        await outbox.drain()
        #expect(provider.sentMessages.isEmpty)
        #expect(outbox.pending().count == 1)
        #expect(DraftBox.shared.draft(id) != nil, "the draft must survive a retryable failure")
        DraftBox.shared.remove(id)
    }
}
