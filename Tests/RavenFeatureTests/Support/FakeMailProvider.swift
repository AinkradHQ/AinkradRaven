import Foundation
@testable import RavenFeature

/// Scriptable provider double. Every behaviour the sync engine must survive is
/// expressed as data here rather than as a mock expectation.
final class FakeMailProvider: MailProvider, @unchecked Sendable {
    let accountID: String
    var pages: [ThreadPage] = []
    var deltas: [MailDelta] = []
    var threadsByID: [String: MailThread] = [:]
    var bodies: [String: MessageBody] = [:]
    var labelList: [MailLabel] = []
    var cursor = "c0"
    /// Errors to throw, keyed by the call that should fail, popped per call.
    var failures: [String: [Error]] = [:]
    private(set) var appliedMutations: [LabelMutation] = []
    private(set) var sentMessages: [OutgoingMessage] = []
    private var pageIndex = 0
    private var deltaIndex = 0

    init(accountID: String = "a1") { self.accountID = accountID }

    private func failIfScripted(_ call: String) throws {
        guard var queue = failures[call], !queue.isEmpty else { return }
        let error = queue.removeFirst()
        failures[call] = queue
        throw error
    }

    /// When true, `fetchThreads` parks on entry until released — the window
    /// in which a test can prove a second `resyncFromScratch()` was refused
    /// (or, if it weren't, would start a second overlapping page walk).
    var holdsFetchThreads = false
    private var fetchThreadsGates: [CheckedContinuation<Void, Never>] = []
    private var fetchThreadsEntryWaiter: CheckedContinuation<Void, Never>?
    private var fetchThreadsHasBeenEntered = false
    /// Counts every call, gated or not — the concurrency test's proof that a
    /// refused `resyncFromScratch()` never reached the provider at all.
    private(set) var fetchThreadsCallCount = 0

    /// Resolves once `fetchThreads` has actually parked, so a test never
    /// races the backfill it is trying to hold open.
    func waitUntilFetchThreadsEntered() async {
        if fetchThreadsHasBeenEntered { return }
        await withCheckedContinuation { continuation in
            fetchThreadsEntryWaiter = continuation
        }
    }

    /// Releases every parked `fetchThreads` call.
    func releaseFetchThreads() {
        holdsFetchThreads = false
        let gates = fetchThreadsGates
        fetchThreadsGates = []
        for gate in gates { gate.resume() }
    }

    func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
        try failIfScripted("fetchThreads")
        fetchThreadsCallCount += 1
        if holdsFetchThreads {
            await withCheckedContinuation { continuation in
                fetchThreadsGates.append(continuation)
                fetchThreadsHasBeenEntered = true
                fetchThreadsEntryWaiter?.resume()
                fetchThreadsEntryWaiter = nil
            }
        }
        guard pageIndex < pages.count else { return ThreadPage(threads: [], nextPageToken: nil) }
        defer { pageIndex += 1 }
        return pages[pageIndex]
    }

    func fetchDelta(cursor: String) async throws -> MailDelta {
        try failIfScripted("fetchDelta")
        guard deltaIndex < deltas.count else {
            return MailDelta(changedThreadIDs: [], removedThreadIDs: [], newCursor: cursor)
        }
        defer { deltaIndex += 1 }
        return deltas[deltaIndex]
    }

    func fetchThread(id: String) async throws -> MailThread {
        try failIfScripted("fetchThread")
        guard let thread = threadsByID[id] else { throw MailError.unknownThread(id) }
        return thread
    }

    func fetchBody(messageID: String) async throws -> MessageBody {
        try failIfScripted("fetchBody")
        return bodies[messageID] ?? MessageBody(messageID: messageID, plainText: "", html: nil)
    }

    var attachmentBytes: [String: Data] = [:]

    func fetchAttachment(messageID: String, attachmentID: String) async throws -> Data {
        try failIfScripted("fetchAttachment")
        return attachmentBytes[attachmentID] ?? Data()
    }

    func fetchLabels() async throws -> [MailLabel] {
        try failIfScripted("fetchLabels")
        return labelList
    }

    func applyLabels(_ mutation: LabelMutation) async throws {
        try failIfScripted("applyLabels")
        appliedMutations.append(mutation)
    }

    // MARK: Gated send
    //
    // Lets a test hold `send` suspended mid-call — the exact window in which
    // `Outbox.drain()` has freed the main actor and a second drain can start.
    // Without a real suspension there is no way to prove non-reentrancy;
    // `Task.yield()` alone would be a race, not a proof.

    /// When true, `send` parks on entry until released.
    var holdsSend = false
    /// A LIST, not a single slot: a reentrant drain enters `send` a second
    /// time, and a single slot would drop the first continuation and deadlock
    /// — turning a real defect into a hung test instead of a failed assertion.
    private var sendGates: [CheckedContinuation<Void, Never>] = []
    private var sendEntryWaiter: CheckedContinuation<Void, Never>?
    private var sendHasBeenEntered = false
    private var gateIsOpen = false
    /// Thrown by `send` AFTER it is released from the gate, so a test can
    /// model "the network call was already in flight and then failed" — the
    /// case where the entry leaves the queue with nothing transmitted.
    var sendErrorAfterGate: Error?

    /// Resolves once `send` has actually been entered and is parked, so the
    /// test never races the drain it is trying to overlap.
    func waitUntilSendEntered() async {
        if sendHasBeenEntered { return }
        await withCheckedContinuation { continuation in
            sendEntryWaiter = continuation
        }
    }

    /// Opens the gate for any FUTURE `send` without releasing the one already
    /// parked. This is what makes the overlap test deterministic: the second
    /// drain either refuses to enter `send` at all (correct) or runs straight
    /// through it and transmits a duplicate (the defect) — never parks, so the
    /// test cannot deadlock and cannot pass by lucky scheduling.
    func allowFutureSends() { gateIsOpen = true }

    /// Releases every parked `send`.
    func releaseSend() {
        gateIsOpen = true
        let gates = sendGates
        sendGates = []
        for gate in gates { gate.resume() }
    }

    func send(_ message: OutgoingMessage) async throws -> String {
        try failIfScripted("send")
        if holdsSend && !gateIsOpen {
            await withCheckedContinuation { continuation in
                sendGates.append(continuation)
                sendHasBeenEntered = true
                sendEntryWaiter?.resume()
                sendEntryWaiter = nil
            }
        }
        if let error = sendErrorAfterGate { throw error }
        sentMessages.append(message)
        return "sent-\(sentMessages.count)"
    }

    func currentCursor() async throws -> String {
        try failIfScripted("currentCursor")
        return cursor
    }
}
