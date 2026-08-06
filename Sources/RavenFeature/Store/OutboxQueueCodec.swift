import Foundation

/// The one seam between the bytes at `DocumentKeys.outbox` and the in-memory
/// queue: everything `Outbox.init` used to do between "here is some data" and
/// "here are my entries", and nothing else. Extracted from `Outbox.swift` for
/// the same reason `OutboxFailure` was — that file is grandfathered past this
/// repo's line limit and must not grow — and it is a real seam rather than a
/// dump because loading is a pure function of the stored bytes (no store, no
/// router, no clock beyond `now`), assertable directly, and it is the only
/// place the queue's on-disk shape is interpreted.
enum OutboxQueueCodec {
    /// What one load of the stored queue produced.
    struct Load {
        let entries: [OutboxEntry]
        /// How many stored entries this build could not decode.
        ///
        /// Counted and exposed rather than swallowed, exactly as
        /// `IMAPMailboxDirectory.refusedLineCount` is. A `try?` on the whole
        /// `[OutboxEntry]` discarded the ENTIRE queue for one unreadable row —
        /// every pending send, every held entry, every one awaiting review,
        /// gone with no error and no trace. Per-entry decoding keeps
        /// everything this build understands; but a silently shorter queue is
        /// its own hazard (indistinguishable from a queue that legitimately
        /// had fewer entries), and an entry the user queued that this build
        /// cannot read is a message that will never be sent. So the count
        /// travels out to `Outbox.unreadableEntryCount` and on to
        /// `RavenRuntime`, which shows it in the Settings attention group.
        let unreadableEntryCount: Int
        /// The stored bytes were present but were not a queue this build could
        /// read AT ALL — a truncated write, corrupt bytes, or a future build
        /// storing something other than a bare array (an object envelope, say).
        ///
        /// A separate flag rather than a count, because the count is genuinely
        /// unknowable here: if the document does not parse there is nothing to
        /// enumerate. Without it, per-entry leniency would fix "one entry I
        /// cannot read" and leave the identical bug one level up — the whole
        /// queue discarded, `unreadableEntryCount == 0`, indistinguishable from
        /// an outbox that was simply empty. The two states read differently to
        /// the user, so they are carried differently here.
        let documentUnreadable: Bool
    }

    /// Decodes the stored queue entry by entry, so one unreadable entry costs
    /// that entry only — an entry written by a newer build, or one carrying a
    /// field this build cannot read, must not take the whole outbox with it.
    ///
    /// Also applies the crash-recovery conversion that has always run on load:
    /// an entry still marked in flight belonged to a process that died mid
    /// operation, so its outcome is unknown and it is held for review rather
    /// than resent. That conversion lives here because it is part of turning
    /// stored bytes back into a trustworthy queue, and it is pure.
    ///
    /// No stored bytes at all is the ordinary first-launch case and is NOT
    /// reported as unreadable; bytes that are present but do not parse as the
    /// queue's array are — see `Load.documentUnreadable`. `LenientEntry`'s
    /// initializer never throws, so a decode failure here means the DOCUMENT
    /// was refused (not an array, or not JSON), never one element.
    static func load(_ data: Data?, decoder: JSONDecoder) -> Load {
        guard let data else {
            return Load(entries: [], unreadableEntryCount: 0, documentUnreadable: false)
        }
        guard let lenient = try? decoder.decode([LenientEntry].self, from: data) else {
            return Load(entries: [], unreadableEntryCount: 0, documentUnreadable: true)
        }
        let entries = lenient.compactMap(\.entry).map(restoreInFlight)
        return Load(entries: entries,
                    unreadableEntryCount: lenient.count - entries.count,
                    documentUnreadable: false)
    }

    private static func restoreInFlight(_ entry: OutboxEntry) -> OutboxEntry {
        var entry = entry
        guard entry.inFlightAt != nil, !entry.isDeadLettered, !entry.needsReview
        else { return entry }
        entry.needsReview = true
        if entry.lastError == nil {
            entry.lastError = "A previous process exited while this operation was " +
                "in flight; whether it reached the provider is unknown. Held for " +
                "manual review rather than resent, to avoid a possible duplicate."
        }
        return entry
    }

    /// Wraps one stored entry so a decode failure produces `nil` instead of
    /// throwing out of the surrounding array — the same shape
    /// `IMAPSyncCursor.LenientState` uses for its mailbox map.
    private struct LenientEntry: Decodable {
        let entry: OutboxEntry?

        init(from decoder: Decoder) throws {
            entry = try? OutboxEntry(from: decoder)
        }
    }
}
