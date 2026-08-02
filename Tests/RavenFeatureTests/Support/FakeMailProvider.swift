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

    func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
        try failIfScripted("fetchThreads")
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

    func fetchLabels() async throws -> [MailLabel] {
        try failIfScripted("fetchLabels")
        return labelList
    }

    func applyLabels(_ mutation: LabelMutation) async throws {
        try failIfScripted("applyLabels")
        appliedMutations.append(mutation)
    }

    func send(_ message: OutgoingMessage) async throws -> String {
        try failIfScripted("send")
        sentMessages.append(message)
        return "sent-\(sentMessages.count)"
    }

    func currentCursor() async throws -> String {
        try failIfScripted("currentCursor")
        return cursor
    }
}
