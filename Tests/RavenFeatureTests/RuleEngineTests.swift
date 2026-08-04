import Testing
import Foundation
@testable import RavenFeature

/// `RuleEngine` is the M3 rules/filters engine: an ordered `RuleSet` applied
/// only to threads a delta sync just discovered, going through the SAME
/// `ThreadMutationApplier`/`Outbox.enqueue` surface every other mutation path
/// (`RavenViewModel`, `RavenMCPOperations`) already shares — never a fourth
/// mutation path, never a provider call of its own.
@Suite("RuleEngine")
@MainActor struct RuleEngineTests {
    /// Seeds the `a1` account row every thread below belongs to.
    ///
    /// Not incidental setup: mutations are rendered through the vocabulary
    /// resolved from the thread's ACCOUNT, so a store holding threads but no
    /// account row is a state where nothing can be safely rendered — and the
    /// engine correctly skips rather than guessing at a backend. That state
    /// cannot occur in production (`attachStoredAccounts()` reads
    /// `store.accounts()` to build a provider, so the row necessarily exists
    /// before any of its threads sync), so seeding it here makes these tests
    /// match production rather than relaxing the engine.
    private func makeStore() -> DocumentMailStore {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        try? store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                           address: "a1@example.test", displayName: "A1",
                                           state: .ready))
        return store
    }

    private func thread(_ id: String, subject: String, from: String,
                        labelIDs: [String] = ["INBOX"]) -> MailThread {
        MailThread(id: id, accountID: "a1", messages: [
            MailMessage(id: "\(id)-m1", threadID: id, from: MailAddress(email: from),
                       subject: subject, date: Date(), labelIDs: labelIDs)
        ])
    }

    // MARK: Matching

    @Test("a condition matches case-insensitively and an empty condition matches nothing")
    func conditionMatching() {
        let summary = thread("t1", subject: "Weekly Newsletter", from: "news@example.com").summary()
        #expect(MailRule.Condition(field: .sender, contains: "NEWS@EXAMPLE").matches(summary))
        #expect(MailRule.Condition(field: .subject, contains: "newsletter").matches(summary))
        #expect(MailRule.Condition(field: .sender, contains: "someone-else").matches(summary) == false)
        #expect(MailRule.Condition(field: .sender, contains: "").matches(summary) == false)
    }

    @Test("a disabled rule or one with no conditions never matches")
    func disabledOrEmptyRuleNeverMatches() {
        let summary = thread("t1", subject: "Anything", from: "a@x.com").summary()
        let disabled = MailRule(name: "r", isEnabled: false,
                                conditions: [.init(field: .subject, contains: "any")], action: .archive)
        #expect(disabled.matches(summary) == false)
        let empty = MailRule(name: "r", conditions: [], action: .archive)
        #expect(empty.matches(summary) == false)
    }

    // MARK: Ordering and stop-processing

    @Test("rules apply in order, and a stopping rule halts subsequent rules for that thread")
    func stoppingRuleHaltsSubsequentRules() throws {
        let store = makeStore()
        try store.upsertThread(thread("t1", subject: "Invoice due", from: "billing@vendor.com"))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let ruleSet = RuleSet(rules: [
            MailRule(name: "archive invoices",
                    conditions: [.init(field: .subject, contains: "invoice")],
                    action: .archive, stopProcessing: true),
            MailRule(name: "also star invoices",
                    conditions: [.init(field: .subject, contains: "invoice")],
                    action: .star(true), stopProcessing: false),
        ])

        RuleEngine.apply(ruleSet: ruleSet, threadIDs: ["t1"], store: store, outbox: outbox)

        let updated = try #require(store.thread("t1"))
        #expect(updated.messages[0].labelIDs.contains("INBOX") == false, "the first rule's archive must have applied")
        #expect(updated.messages[0].isStarred == false,
                "the second rule must never run once the first rule stopped processing")
    }

    @Test("a non-stopping rule lets a later matching rule also run")
    func nonStoppingRuleAllowsLaterRuleToRun() throws {
        let store = makeStore()
        try store.upsertThread(thread("t1", subject: "Invoice due", from: "billing@vendor.com"))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let ruleSet = RuleSet(rules: [
            MailRule(name: "star invoices",
                    conditions: [.init(field: .subject, contains: "invoice")],
                    action: .star(true), stopProcessing: false),
            MailRule(name: "archive invoices",
                    conditions: [.init(field: .subject, contains: "invoice")],
                    action: .archive, stopProcessing: false),
        ])

        RuleEngine.apply(ruleSet: ruleSet, threadIDs: ["t1"], store: store, outbox: outbox)

        let updated = try #require(store.thread("t1"))
        #expect(updated.messages[0].isStarred)
        #expect(updated.messages[0].labelIDs.contains("INBOX") == false)
    }

    // MARK: Shares the ThreadAction/Outbox path — never mutates or sends directly

    @Test("a rule's action is enqueued via the outbox, not applied only in memory")
    func ruleActionIsEnqueuedThroughOutbox() async throws {
        let store = makeStore()
        try store.upsertThread(thread("t1", subject: "Newsletter", from: "news@example.com"))
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)

        let ruleSet = RuleSet(rules: [
            MailRule(name: "archive newsletters",
                    conditions: [.init(field: .subject, contains: "newsletter")],
                    action: .archive),
        ])

        RuleEngine.apply(ruleSet: ruleSet, threadIDs: ["t1"], store: store, outbox: outbox)

        // Local store already reflects it (local-first)...
        #expect(try #require(store.thread("t1")).messages[0].labelIDs.contains("INBOX") == false)
        // ...and the SAME change is queued for the provider, exactly like
        // `RavenViewModel.apply`/`RavenMCPOperations.mutate` — never a direct
        // provider call from the rule engine itself.
        #expect(outbox.pending().count == 1)
        await outbox.drain()
        #expect(provider.appliedMutations.count == 1)
        #expect(provider.appliedMutations.first?.threadIDs == ["t1"])
        #expect(provider.appliedMutations.first?.remove.contains("INBOX") == true)
    }

    @Test("an empty rule set enqueues nothing")
    func emptyRuleSetDoesNothing() throws {
        let store = makeStore()
        try store.upsertThread(thread("t1", subject: "Anything", from: "a@x.com"))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        RuleEngine.apply(ruleSet: RuleSet(), threadIDs: ["t1"], store: store, outbox: outbox)

        #expect(outbox.pending().isEmpty)
    }

    // MARK: Preview count

    @Test("previewCount reports how many of a set of threads a rule would match")
    func previewCountMatchesAgainstSummaries() {
        let summaries = [
            thread("t1", subject: "Invoice", from: "billing@vendor.com").summary(),
            thread("t2", subject: "Invoice reminder", from: "billing@vendor.com").summary(),
            thread("t3", subject: "Hello", from: "friend@example.com").summary(),
        ]
        let rule = MailRule(name: "invoices", conditions: [.init(field: .subject, contains: "invoice")],
                            action: .archive)
        #expect(RuleSet.previewCount(rule, against: summaries) == 2)
    }

    // MARK: Only new arrivals — never retroactive (delta sync integration)

    @Test("SyncEngine.syncDelta reports only the newly-fetched thread ids via onNewThreads, never pre-existing ones")
    func syncDeltaReportsOnlyNewlyArrivedThreads() async throws {
        let store = makeStore()
        // A thread already in the store BEFORE this sync — must never appear
        // in `onNewThreads`, which is the hook `RuleEngine.apply` is driven
        // from; applying rules to this id would be retroactive.
        try store.upsertThread(thread("existing", subject: "Old mail", from: "a@x.com"))
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a1@x.com",
                                          displayName: "A1", syncCursor: "c0"))

        let provider = FakeMailProvider(accountID: "a1")
        provider.threadsByID["new1"] = thread("new1", subject: "Just arrived", from: "b@x.com")
        provider.deltas = [MailDelta(changedThreadIDs: ["new1"], removedThreadIDs: [], newCursor: "c1")]

        let engine = SyncEngine(store: store, provider: provider, accountID: "a1")
        var reported: [String] = []
        engine.onNewThreads = { ids in reported.append(contentsOf: ids) }

        try await engine.syncDelta()

        #expect(reported == ["new1"])
        #expect(reported.contains("existing") == false)
    }

    @Test("rules driven off onNewThreads never touch a pre-existing thread")
    func rulesDoNotTouchPreExistingThreads() throws {
        let store = makeStore()
        // Pre-existing thread that WOULD match the rule if it were (wrongly)
        // included — proves the caller (RavenRuntime, mirrored here) must
        // pass only the ids `onNewThreads` reported, not "everything".
        try store.upsertThread(thread("existing", subject: "Invoice from before", from: "billing@vendor.com"))
        try store.upsertThread(thread("new1", subject: "Invoice just in", from: "billing@vendor.com"))
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())

        let ruleSet = RuleSet(rules: [
            MailRule(name: "archive invoices",
                    conditions: [.init(field: .subject, contains: "invoice")],
                    action: .archive),
        ])

        // Simulates `RavenRuntime.applyRules` being called with exactly the
        // delta-reported ids — NOT the whole store.
        RuleEngine.apply(ruleSet: ruleSet, threadIDs: ["new1"], store: store, outbox: outbox)

        #expect(try #require(store.thread("new1")).messages[0].labelIDs.contains("INBOX") == false)
        #expect(try #require(store.thread("existing")).messages[0].labelIDs.contains("INBOX") == true,
                "a rule application driven off new arrivals must never touch a pre-existing thread")
    }
}
