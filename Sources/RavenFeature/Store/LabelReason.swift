import Foundation

/// One recorded "why" for one `label_with_reason` call on one thread.
///
/// **This never leaves the machine.** It is not part of `LabelMutation`, so no
/// provider — Gmail, Graph, IMAP — can be handed it even by accident: the
/// outbox stores `LabelMutation`s and `MailProvider.applyLabels` takes one, and
/// neither type has a field this could travel in. The reason exists for the
/// user (the thread view shows it) and for an audit of what the agent did, and
/// for nothing else.
public struct LabelReason: Codable, Equatable, Sendable {
    /// The longest reason accepted. A tool argument is model-generated text, so
    /// "unbounded" means one call can write an arbitrarily large document into
    /// a store that has no database behind it — the shard is read, rewritten and
    /// re-encoded on every subsequent call. 500 characters is several sentences
    /// of justification and cannot become a payload.
    public static let maxReasonLength = 500

    public let threadID: String
    /// The label ids this call added and removed, kept alongside the reason so
    /// the record says what was justified and not merely that something was.
    public let add: [String]
    public let remove: [String]
    public let reason: String
    public let recordedAt: Date

    public init(threadID: String, add: [String], remove: [String],
                reason: String, recordedAt: Date) {
        self.threadID = threadID
        self.add = add
        self.remove = remove
        self.reason = reason
        self.recordedAt = recordedAt
    }

    /// Boundary validation: the trimmed reason, or `nil` when it is blank or
    /// longer than `maxReasonLength`.
    ///
    /// Refusing rather than truncating is deliberate and matches
    /// `RavenMCPOperations.boundedLimit`: a silently truncated justification
    /// reads as a complete one, and the caller is never told the record it
    /// asked for is not the record that exists. Whitespace-only is refused for
    /// the same reason — it is indistinguishable from "no reason given" once
    /// stored, which is exactly the state this tool exists to prevent.
    public static func validated(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxReasonLength else { return nil }
        return trimmed
    }
}

/// The one seam between the bytes at `DocumentKeys.labelReasons(accountID:
/// month:)` and a list of `LabelReason`s — modelled on `OutboxQueueCodec`,
/// including why the drop counts are carried out rather than swallowed.
///
/// **The decode rule, in both directions:**
///
/// *Reading* is lenient per ENTRY and tolerant of a wholly unreadable
/// document: one entry this build cannot decode costs that entry only, and the
/// count travels out in `Load.unreadableEntryCount`; a document that does not
/// parse as an array at all yields no entries and sets
/// `Load.documentUnreadable`. Neither ever costs the log, and neither ever
/// costs the account — a reason log is an audit trail, and losing the whole
/// trail (or, worse, the sign-in) because one row is unreadable is exactly the
/// failure `Outbox.init` shipped with.
///
/// *Writing* is strict at the DOCUMENT level and PRESERVING at the entry level.
/// A shard whose bytes do not parse as a JSON array is not rewritten — the
/// append throws `MailError.documentCorrupt` and the original bytes stay on
/// disk, recoverable, exactly as `DocumentMailStore.loadStrict` refuses to
/// clobber. An individual element that parses as JSON but not as a
/// `LabelReason` (a future build's shape, say) is carried through the rewrite
/// untouched rather than dropped: a lenient read may not silently *delete* what
/// it merely cannot display.
///
/// One consequence of that, stated rather than discovered: a preserved element
/// is **never expired**, because expiry reads `recordedAt` and an element this
/// build cannot decode has no readable one. It survives in its shard until
/// `maxEntriesPerShard` evicts it (it is counted in the bound like any other
/// element) or the account is purged. That is bounded, and it is the right side
/// of the trade — the alternative is deleting audit data on the grounds that
/// this build cannot read its timestamp. Asserted by
/// `LabelReasonTests.undecodableEntriesAreNotExpiredByTheWindow`.
enum LabelReasonLog {
    // Deliberately NOT actor-isolated. It reuses `SyncEngine.windowStart` —
    // re-deriving "90 days ago" here is exactly how the reason log would come
    // to disagree with the mail it annotates — and that helper is
    // `nonisolated` because it touches no actor state, so borrowing it costs
    // this codec nothing.
    /// The same 90-day window the inbox and every MCP read tool use, via the
    /// same `SyncEngine.windowStart` — a reason log that outlived the mail it
    /// annotates would be a record of threads the user can no longer see.
    static let windowDays = 90

    /// The most reasons kept per month shard. Bounds the document independently
    /// of the window: a runaway agent could otherwise write an unbounded number
    /// of records inside one month. Oldest first out.
    static let maxEntriesPerShard = 500

    struct Load {
        let entries: [LabelReason]
        /// How many stored entries this build could not decode. Counted and
        /// exposed rather than swallowed, for `OutboxQueueCodec.Load.
        /// unreadableEntryCount`'s reason: a silently shorter log is
        /// indistinguishable from one that legitimately had fewer entries.
        let unreadableEntryCount: Int
        /// The bytes were present but were not an array of entries at all.
        /// A flag rather than a count because the count is unknowable when the
        /// document does not parse.
        let documentUnreadable: Bool
        /// Entries dropped for being older than the 90-day window. Separate
        /// from `unreadableEntryCount` because they are not the same event:
        /// one is expiry working, the other is data this build cannot read.
        let expiredEntryCount: Int
    }

    static func windowStart(from now: Date) -> Date {
        SyncEngine.windowStart(from: now, windowDays: windowDays)
    }

    static func load(_ data: Data?, decoder: JSONDecoder, now: Date) -> Load {
        guard let data else {
            return Load(entries: [], unreadableEntryCount: 0,
                        documentUnreadable: false, expiredEntryCount: 0)
        }
        guard let lenient = try? decoder.decode([LenientReason].self, from: data) else {
            return Load(entries: [], unreadableEntryCount: 0,
                        documentUnreadable: true, expiredEntryCount: 0)
        }
        let decoded = lenient.compactMap(\.reason)
        let cutoff = windowStart(from: now)
        let live = decoded.filter { $0.recordedAt >= cutoff }
        return Load(entries: live,
                    unreadableEntryCount: lenient.count - decoded.count,
                    documentUnreadable: false,
                    expiredEntryCount: decoded.count - live.count)
    }

    /// The bytes to store for `reason` appended to `data`, with expired entries
    /// pruned and the shard bounded.
    ///
    /// Works over `JSONSerialization` elements rather than decoded models so an
    /// element this build cannot decode survives the rewrite — see the type's
    /// decode rule. Throws `MailError.documentCorrupt(key:)` when `data` is
    /// present but is not a JSON array, so the caller writes nothing.
    static func appended(_ reason: LabelReason, to data: Data?, key: String,
                         encoder: JSONEncoder, decoder: JSONDecoder,
                         now: Date) throws -> Data {
        var stored: [Any] = []
        if let data {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
                throw MailError.documentCorrupt(key: key)
            }
            stored = parsed
        }
        let cutoff = windowStart(from: now)
        var kept: [Any] = []
        for element in stored {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? decoder.decode(LabelReason.self, from: elementData) else {
                kept.append(element)   // unreadable here means UNTOUCHED, not dropped
                continue
            }
            if decoded.recordedAt >= cutoff { kept.append(element) }
        }
        kept.append(try JSONSerialization.jsonObject(with: encoder.encode(reason)))
        if kept.count > maxEntriesPerShard {
            kept.removeFirst(kept.count - maxEntriesPerShard)
        }
        return try JSONSerialization.data(withJSONObject: kept)
    }

    /// Wraps one stored entry so a decode failure produces `nil` instead of
    /// throwing out of the surrounding array — the same shape
    /// `OutboxQueueCodec.LenientEntry` uses.
    private struct LenientReason: Decodable {
        let reason: LabelReason?

        init(from decoder: Decoder) throws {
            reason = try? LabelReason(from: decoder)
        }
    }
}
