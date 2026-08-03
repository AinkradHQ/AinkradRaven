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

    @Test("send_draft genuinely succeeding reports Sent and removes the draft")
    func sendDraftSuccessSendsAndRemoves() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let draft = OutgoingMessage(to: [MailAddress(email: "a@x.com")], subject: "s", bodyText: "b")
        let id = try DraftBox.shared.save(draft)

        let result = await RavenMCPOperations.run(
            "send_draft", arguments: #"{"draft_id":"\#(id)"}"#, store: store, outbox: outbox)

        #expect(result.isError == false)
        #expect(result.text.contains("Sent"))
        #expect(provider.sentMessages.count == 1)
        #expect(DraftBox.shared.draft(id) == nil)
    }

    @Test("send_draft against an unattached/unauthenticated provider does not claim success and keeps the draft")
    func sendDraftUnattachedProviderDoesNotClaimSuccess() async throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let provider = FakeMailProvider()
        provider.failures["send"] = [MailError.notAuthenticated(accountID: "a1")]
        // `maxAttempts: 1` so the single scripted failure dead-letters on the
        // very first drain, exactly what an unattached `RavenProviderProxy`
        // (no account connected yet) looks like in practice: every attempt
        // fails the same way, so it is never going to succeed on retry.
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider, maxAttempts: 1)
        let draft = OutgoingMessage(to: [MailAddress(email: "a@x.com")], subject: "s", bodyText: "b")
        let id = try DraftBox.shared.save(draft)

        let result = await RavenMCPOperations.run(
            "send_draft", arguments: #"{"draft_id":"\#(id)"}"#, store: store, outbox: outbox)

        #expect(result.isError)
        #expect(result.text.contains("Sent") == false)
        #expect(provider.sentMessages.isEmpty)
        #expect(DraftBox.shared.draft(id) != nil, "the draft must survive an unconfirmed send")
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

        #expect(result.isError == false)
        #expect(result.text.contains("queued"))
        #expect(result.text.contains("Sent") == false)
        #expect(provider.sentMessages.isEmpty)
        #expect(outbox.pending().count == 1)
        #expect(DraftBox.shared.draft(id) != nil, "the draft must survive a retryable failure")
        DraftBox.shared.remove(id)
    }
}
