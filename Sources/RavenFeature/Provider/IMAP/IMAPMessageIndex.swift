import Foundation

/// What `IMAPProvider` remembers about the messages it has already seen, and the
/// **only** way an `IMAPDeltaIdentity` is built in production.
///
/// ## Why the index exists at all
///
/// Two `MailProvider` calls are answerable for Gmail with one request and are not
/// answerable for IMAP with any number of them:
///
/// - `fetchThread(id:)` is handed a thread id. IMAP has no server-side threads, so
///   the mapping from a locally computed thread id back to the UIDs that compose
///   it exists nowhere on the server.
/// - `applyLabels` is handed thread ids. `UID STORE` needs UIDs and a `SELECT`ed
///   mailbox.
///
/// ## Why it is per-mailbox, structurally
///
/// `IMAPDeltaStrategy`'s fallback derives removals from "known, in range, and
/// absent from the re-scan", so an account-wide `knownUIDs` makes `Folder A`'s
/// re-scan report every message of `Folder B` as deleted — silent mail loss, and
/// the loudest failure available for it is nothing at all. Task 12 could not close
/// that hole because it had no supplier; this type is the supplier, and it closes
/// it two ways:
///
/// 1. `IMAPDeltaIdentity` carries the `mailbox` it belongs to, and
///    `IMAPDeltaStrategy.delta(cursor:)` reads the mailbox from the identity
///    instead of taking it as a separate argument. A caller can therefore no
///    longer pair one mailbox's identity with another mailbox's walk.
/// 2. `identity(for:)` is the only production construction site, and it snapshots
///    exactly one mailbox's UID table. An account-wide identity is not something
///    a caller can ask this type for.
actor IMAPMessageIndex {
    /// What is remembered per UID. Flags are held because the no-CONDSTORE
    /// fallback's whole defence against reporting its entire re-scan as changed is
    /// a comparison against them.
    struct Entry: Sendable, Equatable {
        let threadID: String
        let messageKey: String
        let flags: Set<MailFlag>
    }

    /// mailbox → UID → entry. Never flattened: see the type's documentation.
    private var byMailbox: [String: [UInt32: Entry]] = [:]
    /// mailbox → the sequence-number map of the last walk. An untagged `EXPUNGE`
    /// carries a sequence number and nothing else, so without this a deletion
    /// reported by a non-QRESYNC server resolves to no thread and is dropped.
    private var sequenceNumbers: [String: [UInt64: UInt32]] = [:]
    /// `Message-ID` → thread id, for the arrival path: a freshly fetched message
    /// has no stored UID, so its thread is found either by its own key or by any
    /// id it references.
    private var threadsByMessageKey: [String: String] = [:]
    /// thread id → every locator composing it, in insertion-stable sorted order.
    private var locatorsByThread: [String: Set<IMAPMessageLocator>] = [:]

    // MARK: - Recording

    /// Records one walk's assembled threads.
    ///
    /// Both directions are written from the same source of truth — the assembled
    /// `MailThread`s — rather than one from the threads and the other from the raw
    /// fetches. That is what stops the UID table and the thread table disagreeing
    /// about which thread a UID is in, which would make a removal retire the wrong
    /// thread.
    func record(_ assembled: [IMAPThreadAssembler.Assembled],
                inputs: [IMAPThreadAssembler.Input]) {
        var fetchedByLocator: [String: IMAPFetchResponse] = [:]
        for input in inputs { fetchedByLocator[input.locator.encoded] = input.fetched }

        for entry in assembled {
            // A merge retires ids: their locators must move to the surviving
            // thread or `fetchThread` on the survivor would return a partial
            // thread and `applyLabels` would miss messages.
            for retired in entry.candidateLosingIDs {
                if let moved = locatorsByThread.removeValue(forKey: retired) {
                    locatorsByThread[entry.thread.id, default: []].formUnion(moved)
                    for locator in moved {
                        if var table = byMailbox[locator.mailbox], let held = table[locator.uid] {
                            table[locator.uid] = Entry(threadID: entry.thread.id,
                                                       messageKey: held.messageKey,
                                                       flags: held.flags)
                            byMailbox[locator.mailbox] = table
                            threadsByMessageKey[held.messageKey] = entry.thread.id
                        }
                    }
                }
            }
            for message in entry.thread.messages {
                guard let locator = IMAPMessageLocator(encoded: message.id) else { continue }
                let fetched = fetchedByLocator[message.id]
                let key = fetched.map(IMAPThreadAssembler.messageKey)
                    ?? message.rfc822MessageID ?? message.id
                byMailbox[locator.mailbox, default: [:]][locator.uid] = Entry(
                    threadID: entry.thread.id, messageKey: key,
                    flags: fetched?.flags ?? Self.flags(of: message))
                threadsByMessageKey[key] = entry.thread.id
                locatorsByThread[entry.thread.id, default: []].insert(locator)
                if let sequence = fetched?.sequenceNumber {
                    sequenceNumbers[locator.mailbox, default: [:]][sequence] = locator.uid
                }
            }
        }
    }

    /// Files one message into a thread the index already knows, without
    /// re-threading it.
    ///
    /// The delta path needs this because a lone arrival handed to the assembler is
    /// its own root and would get its own thread id, which the delta has already
    /// reported as belonging to the existing thread. Two records of one message
    /// under two ids is how `fetchThread` starts returning a thread that is missing
    /// its newest message.
    func attach(_ locator: IMAPMessageLocator, fetched: IMAPFetchResponse,
                to threadID: String) {
        let key = IMAPThreadAssembler.messageKey(fetched)
        byMailbox[locator.mailbox, default: [:]][locator.uid] = Entry(
            threadID: threadID, messageKey: key, flags: fetched.flags)
        threadsByMessageKey[key] = threadID
        locatorsByThread[threadID, default: []].insert(locator)
        sequenceNumbers[locator.mailbox, default: [:]][fetched.sequenceNumber] = locator.uid
    }

    /// The canonical flags implied by a stored message, for the one path where the
    /// raw `FETCH` is no longer to hand (a thread rebuilt from the store).
    private static func flags(of message: MailMessage) -> Set<MailFlag> {
        var flags: Set<MailFlag> = []
        if !message.isRead { flags.insert(.unread) }
        if message.isStarred { flags.insert(.starred) }
        return flags
    }

    /// Forgets every UID belonging to `threadIDs`. Called for the removals a delta
    /// reported, so the next pass does not report them a second time.
    func forget(threadIDs: [String]) {
        for id in threadIDs {
            guard let locators = locatorsByThread.removeValue(forKey: id) else { continue }
            for locator in locators {
                if let removed = byMailbox[locator.mailbox]?.removeValue(forKey: locator.uid) {
                    threadsByMessageKey.removeValue(forKey: removed.messageKey)
                }
            }
        }
    }

    /// Discards one mailbox's UID table — for a `UIDVALIDITY` change, where every
    /// UID below is meaningless. Scoped to one mailbox for the same reason
    /// `IMAPSyncCursor.reconcile` is.
    func forget(mailbox: String) {
        guard let table = byMailbox.removeValue(forKey: mailbox) else { return }
        sequenceNumbers.removeValue(forKey: mailbox)
        for entry in table.values { threadsByMessageKey.removeValue(forKey: entry.messageKey) }
        for (thread, locators) in locatorsByThread {
            let kept = locators.filter { $0.mailbox != mailbox }
            if kept.isEmpty { locatorsByThread.removeValue(forKey: thread) }
            else { locatorsByThread[thread] = kept }
        }
    }

    // MARK: - Reading

    /// Where a thread's messages are, oldest UID first per mailbox. Empty for a
    /// thread this provider has never walked, which `fetchThread` reports as
    /// `MailError.unknownThread` rather than as an empty thread.
    func locators(threadID: String) -> [IMAPMessageLocator] {
        (locatorsByThread[threadID] ?? []).sorted { ($0.mailbox, $0.uid) < ($1.mailbox, $1.uid) }
    }

    func threadID(forMessageKey key: String) -> String? { threadsByMessageKey[key] }

    /// One mailbox's delta identity. The only production construction site of an
    /// `IMAPDeltaIdentity`; see the type's documentation for why that matters.
    ///
    /// Every closure closes over an immutable *snapshot* taken here, so the
    /// identity is `Sendable` without the strategy ever re-entering this actor
    /// mid-walk — and, more importantly, so the answers a single pass gets cannot
    /// change underneath it.
    func identity(for mailbox: String) -> IMAPDeltaIdentity {
        let table = byMailbox[mailbox] ?? [:]
        let sequences = sequenceNumbers[mailbox] ?? [:]
        let byKey = threadsByMessageKey
        return IMAPDeltaIdentity(
            mailbox: mailbox,
            knownUIDs: { Set(table.keys) },
            knownFlags: { table[$0]?.flags },
            threadID: { table[$0]?.threadID },
            threadIDForFetched: { fetched in
                if let own = byKey[IMAPThreadAssembler.messageKey(fetched)] { return own }
                // The arrival that LINKS: a message whose own key is unknown but
                // which cites one we hold belongs to that thread. This is what
                // makes an arrival into an existing thread report that thread as
                // changed rather than as a new one.
                for reference in IMAPThreadAssembler.references(fetched) {
                    if let thread = byKey[reference] { return thread }
                }
                return nil
            },
            uidForSequenceNumber: { sequences[$0] })
    }
}

/// Collects the raw `FETCH` responses a delta walk saw, so the provider can
/// assemble them into threads afterwards.
///
/// It rides on `IMAPDeltaIdentity.threadIDForFetched` — the one hook the walk calls
/// for every message it fetched — rather than duplicating the walk. A second
/// arrival fetch issued by the provider would be both a wasted round trip and a
/// second chance to disagree with the strategy about which UIDs are new.
///
/// A lock rather than an actor because the hook it wraps is a synchronous
/// `@Sendable` closure and cannot await.
final class IMAPArrivalCollector: @unchecked Sendable {
    struct Arrival: Sendable {
        let uid: UInt32
        let fetched: IMAPFetchResponse
        /// The thread the index already knew this message belongs to, or `nil` for
        /// one that starts a thread. Recorded here rather than recomputed later
        /// because the index is mutated in between, so asking again would get a
        /// different — and circular — answer.
        let knownThreadID: String?
    }

    private let lock = NSLock()
    private var arrivals: [String: [Arrival]] = [:]

    /// The same identity, with `threadIDForFetched` teed into this collector and
    /// given a provisional answer for a message the index has never seen.
    ///
    /// The provisional id is what the assembler *would* assign if this message
    /// turns out to be its group's root, so for the common single-arrival case it
    /// is already final. Returning `nil` instead would be worse than a provisional
    /// id that gets remapped: `insertThread` falls back to the stored UID, which an
    /// arrival by definition has none of, so the arrival would contribute nothing
    /// and the delta would silently omit new mail.
    func wrapping(_ identity: IMAPDeltaIdentity) -> IMAPDeltaIdentity {
        var wrapped = identity
        let mailbox = identity.mailbox
        let inner = identity.threadIDForFetched
        wrapped.threadIDForFetched = { [self] fetched in
            let known = inner(fetched)
            // A FLAGS-only line carries no ENVELOPE, and for it this hook must answer
            // exactly what the index knows — `nil` included. Returning a provisional id
            // here instead would be actively wrong twice over: it kills
            // `insertThread`'s `?? identity.threadID(uid)` fallback, which is the only
            // way a flag change on a message we already hold is attributed at all, and
            // it manufactures a thread id from a SYNTHETIC message key (there is no
            // `Message-ID` on such a line), so the delta names a thread nothing can
            // resolve. Found by `IMAPProviderTests.removalWinsAcrossMailboxes`, which
            // is the first fixture whose re-scan reports a genuinely changed flag.
            guard let uid = fetched.uid.flatMap({ UInt32(exactly: $0) }),
                  fetched.envelope != nil else { return known }
            record(Arrival(uid: uid, fetched: fetched, knownThreadID: known),
                   mailbox: mailbox)
            if let known { return known }
            // An ARRIVAL, which by definition has no stored UID to fall back to, so a
            // provisional id is the only non-empty answer available. `fetchDelta` remaps
            // it once the batch is assembled.
            return IMAPThreadAssembler.threadID(root: IMAPThreadAssembler.messageKey(fetched))
        }
        return wrapped
    }

    private func record(_ arrival: Arrival, mailbox: String) {
        lock.lock()
        defer { lock.unlock() }
        arrivals[mailbox, default: []].append(arrival)
    }

    /// Everything collected, in a deterministic mailbox order, emptying the buffer.
    func drain() -> [(mailbox: String, arrivals: [Arrival])] {
        lock.lock()
        defer { arrivals.removeAll(); lock.unlock() }
        return arrivals.sorted { $0.key < $1.key }.map { (mailbox: $0.key, arrivals: $0.value) }
    }
}
