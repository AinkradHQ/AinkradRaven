import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// The reason log itself: boundary validation, the decode rule in both
/// directions, the 90-day window, and the sign-out purge.
///
/// Deliberately separate from the tool-level suite in `RavenMCPServerTests`:
/// these are properties of the STORED log, and asserting them through
/// `label_with_reason` would make every one of them depend on a mutation path
/// they have nothing to do with.
@Suite("Label reason log")
@MainActor struct LabelReasonTests {
    private static func reason(_ threadID: String, _ text: String, at date: Date,
                              add: [String] = ["L1"], remove: [String] = []) -> LabelReason {
        LabelReason(threadID: threadID, add: add, remove: remove, reason: text, recordedAt: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Boundary validation

    @Test("a reason is validated at the boundary: trimmed, non-blank, and length-capped")
    func validationIsAtTheBoundary() {
        #expect(LabelReason.maxReasonLength == 500)
        #expect(LabelReason.validated("  Filed as receipts.  ") == "Filed as receipts.")
        #expect(LabelReason.validated("") == nil)
        #expect(LabelReason.validated("   \n\t ") == nil)
        // Exactly at the cap is accepted; one character past it is REFUSED, not
        // truncated — a truncated justification reads as a whole one.
        let atCap = String(repeating: "r", count: LabelReason.maxReasonLength)
        let overCap = String(repeating: "r", count: LabelReason.maxReasonLength + 1)
        #expect(LabelReason.validated(atCap)?.count == LabelReason.maxReasonLength)
        #expect(LabelReason.validated(overCap) == nil)
        // Trimming happens BEFORE the length check, so a reason that is only
        // over the cap because of trailing whitespace is accepted.
        #expect(LabelReason.validated(atCap + "   ")?.count == LabelReason.maxReasonLength)
    }

    // MARK: Reading — lenient per entry, and honest about it

    @Test("one unreadable entry costs that entry only, and the drop is counted, not swallowed")
    func readIsLenientPerEntryAndCountsDrops() throws {
        let now = Date()
        let live = try JSONSerialization.jsonObject(
            with: Self.encoder.encode(Self.reason("t1", "keep me", at: now)))
        // Present, parses as JSON, is NOT a `LabelReason` — a future build's
        // shape, or a truncated field. This is the entry that must cost only
        // itself.
        let unreadable: Any = ["shape": "from a build this one does not know"]
        let expired = try JSONSerialization.jsonObject(
            with: Self.encoder.encode(Self.reason("t2", "too old",
                                                  at: now.addingTimeInterval(-86_400 * 200))))
        let elements: [Any] = [live, unreadable, expired]
        let data = try JSONSerialization.data(withJSONObject: elements)

        let loaded = LabelReasonLog.load(data, decoder: Self.decoder, now: now)

        #expect(loaded.entries.count == 1)
        #expect(loaded.entries.first?.reason == "keep me")
        #expect(loaded.unreadableEntryCount == 1)
        // Expiry and unreadability are counted SEPARATELY: one is the window
        // working, the other is data this build cannot read, and a single
        // "dropped" number could not tell a reviewer which happened.
        #expect(loaded.expiredEntryCount == 1)
        #expect(loaded.documentUnreadable == false)
    }

    @Test("a document that is not a list of records at all is flagged, not reported as empty")
    func wholeDocumentUnreadableIsDistinctFromEmpty() throws {
        let now = Date()
        let notAnArray = try JSONSerialization.data(withJSONObject: ["envelope": ["entries": []]])

        let broken = LabelReasonLog.load(notAnArray, decoder: Self.decoder, now: now)
        let absent = LabelReasonLog.load(nil, decoder: Self.decoder, now: now)
        let empty = LabelReasonLog.load(try JSONSerialization.data(withJSONObject: [Any]()),
                                        decoder: Self.decoder, now: now)

        #expect(broken.entries.isEmpty)
        #expect(broken.documentUnreadable)
        // The two states an unreadable document must not be confused with: no
        // document at all (first launch) and a document that is legitimately
        // an empty list.
        #expect(absent.documentUnreadable == false)
        #expect(empty.documentUnreadable == false)
        #expect(empty.entries.isEmpty)
    }

    // MARK: Writing — strict on the document, preserving on the entry

    @Test("an append onto an unparseable document throws and rewrites nothing")
    func writeRefusesToClobberAnUnreadableDocument() throws {
        let original = Data("{ this is not json at all".utf8)

        // Only the throw is asserted here. Comparing `original` before and after
        // could not fail — `Data` is a value type and `appended` takes it by
        // value, so no implementation could touch the caller's buffer. The
        // "corrupt bytes survive byte-for-byte" property is asserted where it
        // can actually bite, against the document store, in
        // `unreadableShardIsSurvivableAndVisible`.
        #expect(throws: MailError.self) {
            _ = try LabelReasonLog.appended(Self.reason("t1", "why", at: Date()),
                                            to: original, key: "label-reasons-a1-2026-08",
                                            encoder: Self.encoder, decoder: Self.decoder,
                                            now: Date())
        }
    }

    @Test("an append carries through an entry this build cannot decode instead of deleting it")
    func writePreservesUndecodableEntries() throws {
        let now = Date()
        let unreadable: Any = ["shape": "from a newer build"]
        let elements: [Any] = [unreadable]
        let data = try JSONSerialization.data(withJSONObject: elements)

        let updated = try LabelReasonLog.appended(Self.reason("t1", "mine", at: now),
                                                  to: data, key: "k", encoder: Self.encoder,
                                                  decoder: Self.decoder, now: now)

        let rewritten = try #require(JSONSerialization.jsonObject(with: updated) as? [Any])
        #expect(rewritten.count == 2, "the unreadable element must survive the rewrite")
        // The surviving element is the SAME one, identified by its own key —
        // not merely "two elements came back".
        let survived = rewritten.compactMap { ($0 as? [String: Any])?["shape"] as? String }
        #expect(survived == ["from a newer build"])
        // And this build still reads its own entry out of the same document.
        let reloaded = LabelReasonLog.load(updated, decoder: Self.decoder, now: now)
        #expect(reloaded.entries.map(\.reason) == ["mine"])
        #expect(reloaded.unreadableEntryCount == 1)
    }

    /// A consequence of the preserving rule, stated so it is a decision rather
    /// than a surprise: expiry needs `recordedAt`, and an element this build
    /// cannot decode has no readable `recordedAt`, so it can never be aged out.
    /// It lives in its shard until `maxEntriesPerShard` evicts it or the account
    /// is purged — bounded, and preferable to deleting audit data this build
    /// merely cannot display.
    @Test("a preserved undecodable element outlives a prune that expires its sibling")
    func undecodableEntriesAreNotExpiredByTheWindow() throws {
        let now = Date()
        // Deliberately carries a `recordedAt` far outside the window: if expiry
        // were somehow reading it, this element would go. It cannot decode as a
        // `LabelReason` (no `threadID`/`reason`), so it must be preserved.
        let undecodable: Any = ["shape": "from a newer build",
                                "recordedAt": "2020-01-01T00:00:00Z"]
        let expiredSibling = try JSONSerialization.jsonObject(
            with: Self.encoder.encode(Self.reason("t-old", "expired",
                                                  at: now.addingTimeInterval(-86_400 * 200))))
        let data = try JSONSerialization.data(withJSONObject: [undecodable, expiredSibling])

        let updated = try LabelReasonLog.appended(Self.reason("t-new", "fresh", at: now),
                                                  to: data, key: "k", encoder: Self.encoder,
                                                  decoder: Self.decoder, now: now)

        let rewritten = try #require(JSONSerialization.jsonObject(with: updated) as? [Any])
        // The prune DID run — the decodable expired sibling is gone — and the
        // undecodable element survived it anyway. Both halves matter: without
        // the first, "2 elements" would also describe a rewrite that pruned
        // nothing.
        #expect(rewritten.count == 2)
        #expect(rewritten.compactMap { ($0 as? [String: Any])?["shape"] as? String }
                == ["from a newer build"])
        let reloaded = LabelReasonLog.load(updated, decoder: Self.decoder, now: now)
        #expect(reloaded.entries.map(\.threadID) == ["t-new"])
        #expect(reloaded.unreadableEntryCount == 1)
        #expect(reloaded.expiredEntryCount == 0, "the expired sibling was pruned, not filtered")
    }

    @Test("an append prunes entries outside the 90-day window and keeps the ones inside it")
    func writePrunesTheWindow() throws {
        let now = Date()
        let stale = try JSONSerialization.jsonObject(
            with: Self.encoder.encode(Self.reason("t-old", "expired",
                                                  at: now.addingTimeInterval(-86_400 * 120))))
        // 89 days is INSIDE a 90-day window and outside a 30- or 60-day one, so
        // this fixture distinguishes the actual rule from a plausible wrong one.
        let nearEdge = try JSONSerialization.jsonObject(
            with: Self.encoder.encode(Self.reason("t-edge", "just inside",
                                                  at: now.addingTimeInterval(-86_400 * 89))))
        let elements: [Any] = [stale, nearEdge]
        let data = try JSONSerialization.data(withJSONObject: elements)

        let updated = try LabelReasonLog.appended(Self.reason("t-new", "fresh", at: now),
                                                  to: data, key: "k", encoder: Self.encoder,
                                                  decoder: Self.decoder, now: now)

        let reloaded = LabelReasonLog.load(updated, decoder: Self.decoder, now: now)
        #expect(reloaded.entries.count == 2)
        #expect(Set(reloaded.entries.map(\.threadID)) == ["t-edge", "t-new"])
        // Pruned from the stored bytes, not merely filtered on read: the
        // document itself has two elements now.
        let rewritten = try #require(JSONSerialization.jsonObject(with: updated) as? [Any])
        #expect(rewritten.count == 2)
        #expect(LabelReasonLog.windowDays == 90)
    }

    @Test("a shard is bounded, so one runaway caller cannot grow it without limit")
    func shardIsBounded() throws {
        let now = Date()
        var data: Data?
        // One past the cap, so the oldest must have been evicted.
        for index in 0...LabelReasonLog.maxEntriesPerShard {
            data = try LabelReasonLog.appended(
                Self.reason("t\(index)", "reason \(index)", at: now),
                to: data, key: "k", encoder: Self.encoder, decoder: Self.decoder, now: now)
        }
        let loaded = LabelReasonLog.load(data, decoder: Self.decoder, now: now)
        #expect(loaded.entries.count == LabelReasonLog.maxEntriesPerShard)
        // Oldest first out, newest kept.
        #expect(loaded.entries.contains { $0.threadID == "t0" } == false)
        #expect(loaded.entries.contains { $0.threadID == "t\(LabelReasonLog.maxEntriesPerShard)" })
    }

    // MARK: The store

    @Test("the store shards reasons by month, reads them newest-first, and filters by thread")
    func storeShardsAndReads() throws {
        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        let now = Date()
        let earlier = try #require([40.0, 70.0]
            .map { now.addingTimeInterval(-86_400 * $0) }
            .first { MonthShard.key(for: $0) != MonthShard.key(for: now) })

        try store.recordLabelReason(Self.reason("t1", "newest", at: now), accountID: "a1")
        try store.recordLabelReason(Self.reason("t1", "older", at: earlier), accountID: "a1")
        // One second earlier, so the newest-first order is total rather than a
        // tie resolved by whatever order the shards happen to load in.
        try store.recordLabelReason(Self.reason("t2", "other thread",
                                                at: now.addingTimeInterval(-1)), accountID: "a1")
        // Another account's record, to prove the read is account-scoped.
        try store.recordLabelReason(Self.reason("t1", "not a1's", at: now), accountID: "a2")

        let all = store.labelReasons(accountID: "a1", threadID: nil)
        #expect(all.count == 3)
        #expect(all.map(\.reason) == ["newest", "other thread", "older"])
        let forThread = store.labelReasons(accountID: "a1", threadID: "t1")
        #expect(forThread.map(\.reason) == ["newest", "older"])
        #expect(store.labelReasons(accountID: "a2", threadID: "t1").map(\.reason) == ["not a1's"])
        // Two distinct month shards, both registered.
        #expect(documents.storage[DocumentKeys.labelReasons(accountID: "a1",
                                                            month: MonthShard.key(for: now))] != nil)
        #expect(documents.storage[DocumentKeys.labelReasons(accountID: "a1",
                                                            month: MonthShard.key(for: earlier))] != nil)
    }

    @Test("sign-out purge removes every reason shard KEY and the registry, for that account only")
    func purgeRemovesTheReasonKeys() throws {
        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        try store.saveAccount(MailAccount(id: "a1", provider: .gmail, address: "a1@example.test",
                                          displayName: "A1", state: .ready))
        try store.saveAccount(MailAccount(id: "a2", provider: .gmail, address: "a2@example.test",
                                          displayName: "A2", state: .ready))
        let now = Date()
        let earlier = try #require([40.0, 70.0]
            .map { now.addingTimeInterval(-86_400 * $0) }
            .first { MonthShard.key(for: $0) != MonthShard.key(for: now) })
        try store.recordLabelReason(Self.reason("t1", "this month", at: now), accountID: "a1")
        try store.recordLabelReason(Self.reason("t2", "an earlier month", at: earlier),
                                    accountID: "a1")
        try store.recordLabelReason(Self.reason("t3", "another account", at: now), accountID: "a2")

        let keys = [DocumentKeys.labelReasons(accountID: "a1", month: MonthShard.key(for: now)),
                    DocumentKeys.labelReasons(accountID: "a1",
                                              month: MonthShard.key(for: earlier)),
                    DocumentKeys.labelReasonMonths(accountID: "a1")]
        // Every key is PRESENT first: a purge assertion that only checks
        // absence passes just as well against a log that was never written.
        for key in keys { #expect(documents.storage[key] != nil, "precondition: \(key)") }

        try store.purge(accountID: "a1")

        // The KEYS are gone from the document store — not merely "a read comes
        // back empty", which a purge that deleted the registry and stranded the
        // shards would also satisfy.
        for key in keys { #expect(documents.storage[key] == nil, "still on disk: \(key)") }
        #expect(documents.storage.keys.contains { $0.hasPrefix("label-reason") &&
                                                  $0.contains("a1") } == false)
        // The other account's log is untouched.
        #expect(documents.storage[DocumentKeys.labelReasons(accountID: "a2",
                                                            month: MonthShard.key(for: now))] != nil)
        #expect(store.labelReasons(accountID: "a2", threadID: nil).count == 1)
    }

    @Test("an unreadable shard costs neither the log nor the account, and is surfaced")
    func unreadableShardIsSurvivableAndVisible() throws {
        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        let now = Date()
        let earlier = try #require([40.0, 70.0]
            .map { now.addingTimeInterval(-86_400 * $0) }
            .first { MonthShard.key(for: $0) != MonthShard.key(for: now) })
        // A readable shard in one month, a deliberately corrupt one in another.
        try store.recordLabelReason(Self.reason("t1", "readable", at: earlier), accountID: "a1")
        try store.recordLabelReason(Self.reason("t2", "will be clobbered", at: now),
                                    accountID: "a1")
        let brokenKey = DocumentKeys.labelReasons(accountID: "a1", month: MonthShard.key(for: now))
        #expect(store.labelReasons(accountID: "a1", threadID: nil).count == 2)
        let corrupt = Data("not json".utf8)
        documents.setData(corrupt, forKey: brokenKey)

        let survived = store.labelReasons(accountID: "a1", threadID: nil)

        // The other month's records still read, and the account is intact.
        #expect(survived.map(\.reason) == ["readable"])
        #expect(store.unreadableLabelReasonKey == brokenKey)
        // And a write against the corrupt shard refuses rather than replacing
        // it: the bytes are byte-for-byte what they were.
        #expect(throws: MailError.self) {
            try store.recordLabelReason(Self.reason("t3", "new", at: now), accountID: "a1")
        }
        #expect(documents.storage[brokenKey] == corrupt)
    }

    @Test("an entry this build cannot decode is counted, not silently missing")
    func storeCountsUnreadableEntries() throws {
        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        let now = Date()
        try store.recordLabelReason(Self.reason("t1", "mine", at: now), accountID: "a1")
        let key = DocumentKeys.labelReasons(accountID: "a1", month: MonthShard.key(for: now))
        let stored = try #require(documents.storage[key])
        var elements = try #require(JSONSerialization.jsonObject(with: stored) as? [Any])
        #expect(elements.count == 1, "precondition: one stored record")
        elements.append(["shape": "from a newer build"])
        documents.setData(try JSONSerialization.data(withJSONObject: elements), forKey: key)
        #expect(store.unreadableLabelReasonCount == 0)

        let read = store.labelReasons(accountID: "a1", threadID: nil)

        #expect(read.map(\.reason) == ["mine"])
        #expect(store.unreadableLabelReasonCount == 1)
    }
}
