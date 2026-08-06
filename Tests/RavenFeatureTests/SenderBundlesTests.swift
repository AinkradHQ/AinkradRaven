import Testing
import Foundation
@testable import RavenFeature

@Suite("Sender bundles")
struct SenderBundlesTests {
    /// A fixed instant so every date in a fixture is deliberate rather than
    /// "now minus a bit" — the sort is on dates and a fixture whose dates were
    /// incidentally distinct could not distinguish the tie-break rule from no
    /// tie-break rule at all.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func at(_ offset: Double) -> Date { epoch.addingTimeInterval(offset) }

    static func row(_ id: String, _ account: String, _ participants: [MailAddress],
                    _ date: Date, unread: Int = 0) -> ThreadSummary {
        ThreadSummary(id: id, accountID: account, subject: "Subject \(id)",
                      participants: participants, lastMessageDate: date,
                      messageCount: 1, unreadCount: unread, isStarred: false,
                      labelIDs: ["INBOX"], snippet: "s")
    }

    /// Deliberately built so a *plausible wrong* rule still produces a
    /// well-formed bundle list rather than an obviously empty one:
    ///
    /// - `b@example.test` appears three times — once with the display name
    ///   `Bea`, once as `B@Example.Test` with a DIFFERENT display name
    ///   (`Beatrice`), and once with the whole `Bea <b@example.test>` string
    ///   sitting in the address field. Grouping on the raw `email` (which is
    ///   what `unread_summary` does today) yields three separate, plausible
    ///   bundles instead of one.
    /// - `c@example.test` appears twice across TWO accounts, so a rule that
    ///   grouped per account would also look right.
    /// - `t-none` has no participant at all, so a rule that dropped it would
    ///   still return a tidy list — just one with a thread missing.
    static var fixture: [ThreadSummary] {
        [
            row("t-b1", "a1", [MailAddress(email: "b@example.test", name: "Bea")], at(300)),
            row("t-b2", "a1", [MailAddress(email: "B@Example.Test", name: "Beatrice")],
                at(500), unread: 2),
            row("t-b3", "a2", [MailAddress(email: "Bea <b@example.test>")], at(100)),
            row("t-none", "a1", [], at(400), unread: 1),
            row("t-c1", "a1", [MailAddress(email: "c@example.test")], at(200)),
            row("t-c2", "a2", [MailAddress(email: "c@example.test")], at(600), unread: 3),
        ]
    }

    @Test("case and display names normalise to one sender, and a missing sender gets its own bucket")
    func normalisation() throws {
        let rows = Self.fixture
        #expect(rows.count == 6)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 3, "b@example.test ×3, c@example.test ×2, unknown ×1")

        let senders = bundles.map(\.sender)
        #expect(senders == [.address("b@example.test"), .address("c@example.test"), .unknown])

        let b = try #require(bundles.first { $0.sender == .address("b@example.test") })
        #expect(b.threadCount == 3)
        #expect(b.threadIDs == ["t-b2", "t-b1", "t-b3"], "newest first")
        #expect(b.unreadThreadCount == 1)
        #expect(b.newestDate == Self.at(500))

        let unknown = try #require(bundles.first { $0.sender == .unknown })
        #expect(unknown.threadCount == 1)
        #expect(unknown.threadIDs == ["t-none"])
        #expect(unknown.sender.label == "(unknown sender)")
    }

    @Test("bundles span accounts and carry per-account counts")
    func perAccountAttribution() throws {
        let rows = Self.fixture
        #expect(rows.count == 6)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 3)

        let b = try #require(bundles.first { $0.sender == .address("b@example.test") })
        #expect(b.accounts == [SenderBundles.AccountTally(accountID: "a1", count: 2),
                               SenderBundles.AccountTally(accountID: "a2", count: 1)])
        let c = try #require(bundles.first { $0.sender == .address("c@example.test") })
        #expect(c.accountIDs == ["a1", "a2"])
        #expect(c.accounts == [SenderBundles.AccountTally(accountID: "a1", count: 1),
                               SenderBundles.AccountTally(accountID: "a2", count: 1)])
    }

    @Test("sorted by thread count, then newest date")
    func sortsByCountThenDate() {
        // Two senders with one thread each and different dates, plus one with
        // two threads whose newest date is the OLDEST of the three — so a rule
        // that sorted by date alone would order these differently.
        let rows = [
            Self.row("t1", "a1", [MailAddress(email: "one@example.test")], Self.at(10)),
            Self.row("t2", "a1", [MailAddress(email: "one@example.test")], Self.at(20)),
            Self.row("t3", "a1", [MailAddress(email: "two@example.test")], Self.at(900)),
            Self.row("t4", "a1", [MailAddress(email: "three@example.test")], Self.at(800)),
        ]
        #expect(rows.count == 4)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 3)
        #expect(bundles.map(\.sender) == [.address("one@example.test"),
                                          .address("two@example.test"),
                                          .address("three@example.test")])
        #expect(bundles.map(\.threadCount) == [2, 1, 1])
    }

    @Test("count and date ties break on the normalised address, so the order is total")
    func tieBreakIsTotal() {
        // Identical count (1) and identical date, inserted in an order that is
        // NOT the expected output order — the only thing that can produce the
        // expectation below is the address tie-break.
        let same = Self.at(42)
        let rows = [
            Self.row("t-z", "a1", [MailAddress(email: "z@example.test")], same),
            Self.row("t-m", "a1", [MailAddress(email: "M@Example.Test")], same),
            Self.row("t-a", "a1", [MailAddress(email: "a@example.test")], same),
        ]
        #expect(rows.count == 3)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 3)
        #expect(bundles.map(\.sender) == [.address("a@example.test"),
                                          .address("m@example.test"),
                                          .address("z@example.test")])
        // Repeating the call must give the same order. Swift seeds `Dictionary`
        // hashing per process, so this cannot catch cross-run instability on its
        // own — the tie-break above is what does that. This asserts the weaker
        // but still necessary property that the function is not order-dependent
        // on its own grouping pass within a run.
        #expect(SenderBundles.bundle(rows.reversed(), limit: 25).map(\.sender)
                == bundles.map(\.sender))
    }

    @Test("the unknown bucket sorts after a real address it ties with, never merged into one")
    func unknownTiesLast() {
        let same = Self.at(7)
        let rows = [
            Self.row("t-none", "a1", [], same),
            Self.row("t-zzz", "a1", [MailAddress(email: "zzz@example.test")], same),
        ]
        #expect(rows.count == 2)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 2, "an unrecorded sender is never merged with a real one")
        #expect(bundles.map(\.sender) == [.address("zzz@example.test"), .unknown])
    }

    @Test("an address field holding only a display name or whitespace is unknown, not an empty sender")
    func emptyAddressIsUnknown() {
        let rows = [
            Self.row("t1", "a1", [MailAddress(email: "", name: "Bea")], Self.at(1)),
            Self.row("t2", "a1", [MailAddress(email: "   ", name: nil)], Self.at(2)),
        ]
        #expect(rows.count == 2)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 1)
        #expect(bundles.map(\.sender) == [.unknown])
        #expect(bundles.first?.threadCount == 2)
    }

    @Test("threads sharing a lastMessageDate inside one bundle order by thread id")
    func threadOrderTieBreaksOnID() {
        // Two threads from one sender with the SAME timestamp — routine for a
        // bulk sender, and the case every other fixture here misses because its
        // dates are all distinct. Inserted t-b BEFORE t-a so insertion order is
        // the wrong answer: `Array.sorted(by:)` is not documented as stable, so
        // without the id tie-break the order inside the bundle is whatever the
        // sort implementation happens to produce.
        let same = Self.at(77)
        let rows = [
            Self.row("t-b", "a1", [MailAddress(email: "bulk@example.test")], same),
            Self.row("t-a", "a1", [MailAddress(email: "bulk@example.test")], same),
        ]
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["t-b", "t-a"], "the fixture must start in the wrong order")

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 1)
        #expect(bundles.first?.threadIDs == ["t-a", "t-b"])
        // Same rows, opposite insertion order, same answer.
        #expect(SenderBundles.bundle(rows.reversed(), limit: 25).first?.threadIDs
                == ["t-a", "t-b"])
    }

    @Test("a thread with several participants bundles under the first, as the other tools read it")
    func firstParticipantIsTheSender() {
        // `ThreadSummary.participants` is ordered oldest message first
        // (`MailThread.summary`), so `first` is the sender who started the
        // thread — the same field `unread_summary` and the thread lines in
        // `search_mail` already treat as the sender. Taking the last would
        // silently re-attribute a thread to whoever replied most recently.
        let rows = [
            Self.row("t1", "a1", [MailAddress(email: "starter@example.test"),
                                  MailAddress(email: "replier@example.test")], Self.at(5)),
        ]
        #expect(rows.count == 1)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 1)
        #expect(bundles.map(\.sender) == [.address("starter@example.test")])
    }

    @Test("limit bounds the number of senders, keeping the largest, not the threads inside them")
    func limitTruncatesBundles() {
        let rows = Self.fixture
        #expect(rows.count == 6)

        let bundles = SenderBundles.bundle(rows, limit: 2)
        #expect(bundles.count == 2)
        #expect(bundles.map(\.sender) == [.address("b@example.test"),
                                          .address("c@example.test")])
        // The surviving bundles' counts are NOT reduced by the limit.
        #expect(bundles.first?.threadIDs.count == 3)
    }

    @Test("rendered output names every bundle's accounts and thread ids")
    func rendering() {
        let rows = Self.fixture
        #expect(rows.count == 6)

        let bundles = SenderBundles.bundle(rows, limit: 25)
        #expect(bundles.count == 3)

        let text = SenderBundles.render(bundles, totalThreads: rows.count)
        #expect(text.contains("3 sender(s) over 6 thread(s)"))
        #expect(text.contains("b@example.test · 3 thread(s), 1 unread"))
        #expect(text.contains("accounts a1=2, a2=1"))
        #expect(text.contains("threads t-b2, t-b1, t-b3"))
        #expect(text.contains("(unknown sender) · 1 thread(s)"))
        // The raw display-name form never reaches the wire as a sender label:
        // the whole point is that it was folded into the address bundle.
        #expect(text.contains("Bea <") == false)
        #expect(text.contains("B@Example.Test") == false)
    }
}
