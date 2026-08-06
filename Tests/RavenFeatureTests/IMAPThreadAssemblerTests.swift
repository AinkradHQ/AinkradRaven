import Testing
import Foundation
@testable import RavenFeature

/// Task 13: thread identity, and the merge a linking message causes.
///
/// Nothing here touches a session — every test drives the assembler from recorded
/// `FETCH` bytes — so a failure is always about identity and never about the wire.
@Suite("IMAP thread assembler")
struct IMAPThreadAssemblerTests {

    private static let assembler = IMAPThreadAssembler(accountID: IMAPProviderHarness.accountID)

    /// The two ids the fixtures' roots must hash to, written out as literals.
    ///
    /// Deliberately NOT computed by calling `IMAPStableHash.hex` — an expectation
    /// produced by the code under test asserts only that the code is
    /// self-consistent, which a `UUID()` implementation would also satisfy as long
    /// as it were memoised. These are FNV-1a/64 of the two `Message-ID`s, computed
    /// independently; if the hash function is ever changed on purpose, these change
    /// with it and every stored thread document is orphaned — which is exactly the
    /// decision that should be forced to be explicit.
    private static let m1ThreadID = "imapt-88099c778cf88fc9"
    private static let m2ThreadID = "imapt-d6873810d2590c36"

    // MARK: - Stability

    @Test("the same mailbox parsed twice yields identical thread ids")
    func threadIDsAreStableAcrossTwoParses() throws {
        let first = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked"))
        let second = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked"))
        #expect(first.map(\.thread.id) == second.map(\.thread.id))
        // And they are the ids the root's `Message-ID` hashes to, not merely equal
        // to each other: two runs of a per-process-seeded hash inside ONE process
        // would also be equal.
        #expect(first.map(\.thread.id) == [Self.m1ThreadID])
    }

    @Test("a UIDVALIDITY change does not change any thread id")
    func threadIDsSurviveAUIDVALIDITYChange() throws {
        let original = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", uidValidity: 7))
        let regenerated = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked", uidValidity: 99))
        #expect(original.map(\.thread.id) == regenerated.map(\.thread.id))
        #expect(original.map(\.thread.id) == [Self.m1ThreadID])
        // The MESSAGE ids must differ across the generation, which is what makes the
        // thread-id equality above meaningful: it proves the thread id is not merely
        // being copied from something that also happened not to change.
        let before = original.flatMap { $0.thread.messages.map(\.id) }
        let after = regenerated.flatMap { $0.thread.messages.map(\.id) }
        #expect(Set(before).isDisjoint(with: Set(after)))
        #expect(before.allSatisfy { IMAPMessageLocator(encoded: $0)?.uidValidity == 7 })
        #expect(after.allSatisfy { IMAPMessageLocator(encoded: $0)?.uidValidity == 99 })
    }

    @Test("the id is the root Message-ID's hash, and the root is not the newest message")
    func threadIDComesFromTheRoot() throws {
        let assembled = try #require(Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked")).first)
        #expect(assembled.thread.id == Self.m1ThreadID)
        // The linking message m3 is both the newest and the highest UID, so an
        // implementation keyed on either would produce m3's hash. Pinning the
        // NEGATIVE is what distinguishes "root" from the two plausible wrong rules.
        #expect(assembled.thread.id != "imapt-ebadcda45b6f4f83")
        #expect(assembled.thread.messages.map(\.subject) == ["Subject 2", "Subject 1", "Subject 3"])
    }

    // MARK: - Grouping

    @Test("two unrelated roots stay two threads")
    func unrelatedRootsDoNotMerge() throws {
        let assembled = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-two-threads"))
        #expect(assembled.map(\.thread.id).sorted() == [Self.m1ThreadID, Self.m2ThreadID].sorted())
        #expect(assembled.allSatisfy { $0.thread.messages.count == 1 })
    }

    @Test("a message citing two roots produces one thread that retires the loser's id")
    func linkingMessageMergesAndNamesTheLoser() throws {
        // The loser's id is read off an INDEPENDENT parse of the pre-merge mailbox,
        // not computed from the merge — so this asserts the two agree rather than
        // asserting the merge agrees with itself.
        let before = Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-two-threads"))
        let loser = try #require(before.first { $0.thread.id != Self.m1ThreadID }).thread.id

        let after = try #require(Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked")).first)
        #expect(after.thread.messages.count == 3)
        #expect(after.candidateLosingIDs.contains(loser))
        // The surviving id must NOT be in its own losing list, or the merge would
        // delete the thread it just wrote.
        #expect(!after.candidateLosingIDs.contains(after.thread.id))
    }

    @Test("a message with no Message-ID is keyed synthetically, never by its UID")
    func missingMessageIDDoesNotFallBackToTheUID() throws {
        let wire = """
        * 1 FETCH (UID 41 FLAGS () ENVELOPE ("Sat, 01 Aug 2026 09:00:00 +0000" \
        "Subject 9" (("Name A" NIL "a" "example.test")) NIL NIL NIL NIL NIL NIL NIL))\r\n
        """
        let fetched = try IMAPFetchWire.parsedLine(wire)
        let low = IMAPThreadAssembler.Input(
            locator: IMAPMessageLocator(mailbox: "INBOX", uidValidity: 7, uid: 41),
            fetched: fetched)
        let high = IMAPThreadAssembler.Input(
            locator: IMAPMessageLocator(mailbox: "INBOX", uidValidity: 7, uid: 9_000),
            fetched: fetched)
        let first = try #require(Self.assembler.assemble([low]).first)
        let second = try #require(Self.assembler.assemble([high]).first)
        // Same message, two UIDs, one thread id: the synthetic key is built from
        // envelope fields, so it cannot have borrowed the UID.
        #expect(first.thread.id == second.thread.id)
        #expect(!first.thread.id.contains("41"))
    }

    // MARK: - Locators

    @Test("a locator round-trips through a message id, including a dotted mailbox name")
    func locatorRoundTrips() throws {
        // Dovecot's maildir++ layout uses `.` as the hierarchy delimiter, so a
        // mailbox name containing the field separator is the normal case, not an
        // edge one. A naive `split(".")` decode reads this as a different mailbox.
        let locator = IMAPMessageLocator(mailbox: "INBOX.Folder A.Sub",
                                        uidValidity: 7, uid: 12)
        let decoded = try #require(IMAPMessageLocator(encoded: locator.encoded))
        #expect(decoded == locator)
    }

    @Test("a message id this build did not mint is refused rather than guessed")
    func foreignMessageIDIsRefused() {
        // A Gmail message id. Returning a locator with a guessed UID here is how a
        // cross-provider id would end up `STORE`ing flags onto somebody else's mail.
        #expect(IMAPMessageLocator(encoded: "18f0a1b2c3d4e5f6") == nil)
        #expect(IMAPMessageLocator(encoded: "imap.7.12") == nil)
        #expect(IMAPMessageLocator(encoded: "imap.7.12.!!!!") == nil)
    }

    // MARK: - Committing to the store

    /// The whole point of `mergeThreads`: after a merge the losing thread must be
    /// gone from **every** month shard, not merely from the one the survivor lives
    /// in. m2 is dated July and m1/m3 August, so the loser's index row is in a
    /// different shard from the survivor's — a sweep that only cleaned the surviving
    /// month would leave a row pointing at a deleted document, and the inbox would
    /// show a thread that cannot be opened.
    @MainActor
    @Test("a merge leaves the losing thread in no index shard")
    func mergeSweepsEveryShard() throws {
        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        let assembler = IMAPThreadAssembler(accountID: IMAPProviderHarness.accountID)

        try IMAPThreadAssembler.commit(
            assembler.assemble(try IMAPProviderHarness.inputs("imap-provider-fetch-two-threads")),
            to: store)
        let months = ["2026-07", "2026-08"]
        #expect(Set(store.summaries(accountID: IMAPProviderHarness.accountID, months: months)
            .map(\.id)) == [Self.m1ThreadID, Self.m2ThreadID])
        #expect(store.thread(Self.m2ThreadID) != nil)

        try IMAPThreadAssembler.commit(
            assembler.assemble(try IMAPProviderHarness.inputs("imap-provider-fetch-linked")),
            to: store)

        // The thread document is gone…
        #expect(store.thread(Self.m2ThreadID) == nil)
        // …and so is its row, in BOTH shards. Read through `summaries` (which the
        // inbox uses) and then again straight off the July shard document, because
        // `summaries` sorts and merges and could mask a stale row that a shard read
        // would show.
        let rows = store.summaries(accountID: IMAPProviderHarness.accountID, months: months)
        #expect(rows.map(\.id) == [Self.m1ThreadID])
        let julyKey = DocumentKeys.index(accountID: IMAPProviderHarness.accountID,
                                        month: "2026-07")
        let july = try JSONDecoder.iso8601.decode(
            [ThreadSummary].self, from: try #require(documents.data(forKey: julyKey)))
        #expect(july.isEmpty)
        // The merged thread kept July's message rather than dropping it.
        #expect(store.thread(Self.m1ThreadID)?.messages.count == 3)
    }

    @MainActor
    @Test("an ordinary multi-message thread does not take the destructive merge path")
    func growingAThreadDoesNotMerge() throws {
        // `candidateLosingIDs` is non-empty for every multi-message thread, so without
        // `commit`'s filter EVERY sync pass would run `mergeThreads` — a document
        // delete plus a sweep of every shard — for a thread that has simply gained a
        // reply. The two paths leave the store in the SAME state here, so only the
        // call count can tell them apart. See `MergeCountingStore`.
        let store = IMAPProviderHarness.MergeCountingStore(documents: InMemoryDocumentStore())
        let assembler = IMAPThreadAssembler(accountID: IMAPProviderHarness.accountID)
        try IMAPThreadAssembler.commit(
            assembler.assemble(try IMAPProviderHarness.inputs("imap-provider-fetch-linked")),
            to: store)
        #expect(store.mergeCount == 0)
        #expect(store.upsertCount == 1)
        #expect(store.thread(Self.m1ThreadID)?.messages.count == 3)
        #expect(store.summaries(accountID: IMAPProviderHarness.accountID,
                                months: ["2026-07", "2026-08"]).map(\.id) == [Self.m1ThreadID])
    }

    @MainActor
    @Test("a real merge does take the merge path, exactly once")
    func realMergeCallsMergeThreads() throws {
        let store = IMAPProviderHarness.MergeCountingStore(documents: InMemoryDocumentStore())
        let assembler = IMAPThreadAssembler(accountID: IMAPProviderHarness.accountID)
        try IMAPThreadAssembler.commit(
            assembler.assemble(try IMAPProviderHarness.inputs("imap-provider-fetch-two-threads")),
            to: store)
        #expect(store.mergeCount == 0)
        try IMAPThreadAssembler.commit(
            assembler.assemble(try IMAPProviderHarness.inputs("imap-provider-fetch-linked")),
            to: store)
        // Exactly one merge, not one per candidate: `mergeThreads` retires the whole
        // losing set in a single sweep, and calling it per id would sweep every month
        // shard once per retired thread.
        #expect(store.mergeCount == 1)
    }

    @Test("an unnamed inline part still means the message has an attachment")
    func unnamedInlinePartSetsHasAttachments() throws {
        // The Gmail divergence this task fixed. `Subject 3` is a `multipart/mixed`
        // carrying a text part and an `image/png` with `Content-Disposition: inline`
        // and NO filename — the normal shape of an HTML newsletter's images. Gmail
        // shows a paperclip; the old `!attachments.isEmpty` rule did not.
        let assembled = try #require(Self.assembler.assemble(
            try IMAPProviderHarness.inputs("imap-provider-fetch-linked")).first)
        let message = try #require(assembled.thread.messages.first { $0.subject == "Subject 3" })
        #expect(message.hasAttachments)
        // And it is still not in the saveable list, because the UI cannot offer to
        // save a file with no name. The two answers are deliberately different.
        #expect(message.attachments.isEmpty)
        // A plain-text-only message must NOT gain a paperclip from the looser rule.
        let plain = try #require(assembled.thread.messages.first { $0.subject == "Subject 1" })
        #expect(!plain.hasAttachments)
    }
}

extension JSONDecoder {
    /// The decoder `DocumentMailStore` writes with. A default `JSONDecoder` reads
    /// its ISO-8601 dates as a type mismatch, so a test reading a shard document
    /// directly must match it.
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
