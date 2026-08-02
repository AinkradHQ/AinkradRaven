import Testing
import Foundation
@testable import MailFeature

@Suite("Month sharding")
struct MonthShardTests {
    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try #require(formatter.date(from: iso))
    }

    @Test("a date maps to its UTC year-month key")
    func keyForDate() throws {
        #expect(MonthShard.key(for: try date("2026-03-17T12:00:00Z")) == "2026-03")
    }

    @Test("a range spanning a year boundary lists every month inclusively")
    func rangeAcrossYear() throws {
        let keys = MonthShard.keys(from: try date("2025-11-02T00:00:00Z"),
                                   to: try date("2026-01-20T00:00:00Z"))
        #expect(keys == ["2025-11", "2025-12", "2026-01"])
    }

    @Test("a range inside one month yields one key")
    func singleMonth() throws {
        let keys = MonthShard.keys(from: try date("2026-01-02T00:00:00Z"),
                                   to: try date("2026-01-20T00:00:00Z"))
        #expect(keys == ["2026-01"])
    }

    @Test("an inverted range yields nothing rather than looping")
    func invertedRange() throws {
        let keys = MonthShard.keys(from: try date("2026-05-01T00:00:00Z"),
                                   to: try date("2026-01-01T00:00:00Z"))
        #expect(keys.isEmpty)
    }

    @Test("document keys are stable and namespaced")
    func documentKeys() {
        #expect(DocumentKeys.accounts == "accounts")
        #expect(DocumentKeys.index(accountID: "a1", month: "2026-03") == "index-a1-2026-03")
        #expect(DocumentKeys.thread("t1") == "thread-t1")
        #expect(DocumentKeys.body("m1") == "body-m1")
        #expect(DocumentKeys.labels(accountID: "a1") == "labels-a1")
        #expect(DocumentKeys.outbox == "outbox")
    }
}
