import Testing
import Foundation
@testable import RavenFeature

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

    @Test("UTC boundary: just after midnight UTC on the 1st is in that month")
    func utcBoundaryAfterMidnightOnFirst() throws {
        // 2026-03-01T00:30:00Z is just after midnight UTC on March 1st.
        // In a negative-offset zone (e.g., America/Los_Angeles), this would still be in February.
        // The UTC calendar must correctly yield "2026-03".
        #expect(MonthShard.key(for: try date("2026-03-01T00:30:00Z")) == "2026-03")
    }

    @Test("UTC boundary: just before midnight UTC on the last day is in that month")
    func utcBoundaryBeforeMidnightOnLastDay() throws {
        // 2026-02-28T23:30:00Z is just before midnight UTC on the last day of February.
        // In a positive-offset zone (e.g., Asia/Tokyo), this would already be in March.
        // The UTC calendar must correctly yield "2026-02".
        #expect(MonthShard.key(for: try date("2026-02-28T23:30:00Z")) == "2026-02")
    }

    @Test("UTC boundary: range containing month boundary uses UTC, not local time")
    func utcBoundaryRange() throws {
        // Range from 2026-02-28T23:30:00Z (before midnight UTC on last day of Feb)
        // to 2026-03-01T00:30:00Z (after midnight UTC on first day of Mar).
        // Even in a timezone that would shift these to adjacent days locally,
        // the UTC calendar must yield both "2026-02" and "2026-03".
        let keys = MonthShard.keys(from: try date("2026-02-28T23:30:00Z"),
                                   to: try date("2026-03-01T00:30:00Z"))
        #expect(keys == ["2026-02", "2026-03"])
    }
}
