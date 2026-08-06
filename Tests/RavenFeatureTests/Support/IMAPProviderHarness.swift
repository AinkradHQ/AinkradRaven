import Testing
import Foundation
@testable import RavenFeature

/// The scripted account `IMAPProviderTests` and `IMAPThreadAssemblerTests` drive.
///
/// Split out of both suites for the repo's line limit, and because the two need
/// the same `IMAPMailboxDirectory` and the same fixture messages: an assembler test
/// asserting a thread id and a provider test asserting the merge that id causes
/// must be talking about the same mailbox, or neither proves anything about the
/// other.
enum IMAPProviderHarness {

    /// The account's mailboxes.
    ///
    /// Read from `imap-provider-list.txt` rather than built inline, so the
    /// `\Archive`/`\Trash` SPECIAL-USE attributes go through the real
    /// `IMAPMailboxList` parse. The archive is named `Folder B` and the trash
    /// `Folder C` on purpose: a provider that guessed `"Archive"`/`"Trash"` would
    /// send a mailbox this account does not have, and every recorded-bytes
    /// assertion below would fail rather than passing on a lucky name.
    static func directory() throws -> IMAPMailboxDirectory {
        IMAPMailboxDirectory(untagged: try IMAPFetchWire.untaggedResponses(
            try IMAPFetchWire.fixture("imap-provider-list")))
    }

    static let accountID = "acct-1"

    /// Counts the leases a provider took and gave back.
    ///
    /// The acquire/release balance is the only thing that can catch a missing release:
    /// a scripted session behaves identically whether or not it was handed back, so
    /// nothing about the recorded bytes or the returned values would change. This is
    /// the same reason `MergeCountingStore` exists.
    actor LeaseRecorder {
        private(set) var acquired = 0
        private(set) var released = 0
        func noteAcquired() { acquired += 1 }
        func noteReleased() { released += 1 }
        var isBalanced: Bool { acquired == released && acquired > 0 }
    }

    /// A provider whose `acquire` closure hands back one scripted session and the
    /// directory above.
    ///
    /// The session is built by `IMAPDeltaHarness.session`, so the tags the steps
    /// answer with are `A0001…A000n` **in step order** — which makes the step list
    /// an assertion in itself: a provider that issues its commands in a different
    /// order gets a tag that matches no in-flight command, nothing settles, and the
    /// bounded deadline reports it. A wrong command order cannot pass here.
    /// - Parameter closesOnRelease: when true the lease's `release` runs the REAL
    ///   production teardown (`IMAPProvider.closeSession`), so a suite can assert what
    ///   production actually does to the connection. Default false, because the
    ///   scripted session is shared across the several operations most tests perform
    ///   and closing it after the first would fail every later one for the wrong
    ///   reason — the balance, not the teardown, is what those tests are checking.
    static func provider(capabilities: String = "IMAP4rev1",
                         steps: [IMAPDeltaHarness.Step],
                         pageSize: Int = 50,
                         closesOnRelease: Bool = false) async throws
        -> (IMAPProvider, ScriptedTransport, IMAPSession, LeaseRecorder) {
        let (session, transport) = try await IMAPDeltaHarness.session(
            capabilities: capabilities, steps: steps)
        let working = IMAPWorkingSession(session: session, directory: try directory())
        let leases = LeaseRecorder()
        let provider = IMAPProvider(accountID: accountID, pageSize: pageSize) {
            await leases.noteAcquired()
            return IMAPSessionLease(working: working) {
                await leases.noteReleased()
                if closesOnRelease { await IMAPProvider.closeSession(working) }
            }
        }
        return (provider, transport, session, leases)
    }

    /// The assembler inputs a fixture describes, as if fetched from `mailbox` at
    /// `uidValidity`.
    static func inputs(_ fixture: String, mailbox: String = "INBOX",
                       uidValidity: UInt32 = 7) throws -> [IMAPThreadAssembler.Input] {
        try IMAPFetchWire.parsed(fixture).compactMap { fetched in
            guard let uid = fetched.uid.flatMap({ UInt32(exactly: $0) }) else { return nil }
            return IMAPThreadAssembler.Input(
                locator: IMAPMessageLocator(mailbox: mailbox, uidValidity: uidValidity,
                                            uid: uid),
                fetched: fetched)
        }
    }

    /// A `DocumentMailStore` that counts which write path a commit took.
    ///
    /// Needed because `mergeThreads` and `upsertThread` are OBSERVATIONALLY IDENTICAL
    /// for a thread with no stored losers — the merge loads each unknown id, skips
    /// it, and writes the same document. So a test that only inspected the store
    /// could not tell whether `IMAPThreadAssembler.commit` filtered its candidates
    /// or ran the destructive path on every ordinary sync pass. Counting the call is
    /// the only way to assert the filter.
    @MainActor
    final class MergeCountingStore: MailStore {
        private let inner: DocumentMailStore
        private(set) var mergeCount = 0
        private(set) var upsertCount = 0

        init(documents: InMemoryDocumentStore) {
            inner = DocumentMailStore(documents: documents)
        }

        func mergeThreads(losingIDs: [String], into thread: MailThread) throws {
            mergeCount += 1
            try inner.mergeThreads(losingIDs: losingIDs, into: thread)
        }
        func upsertThread(_ thread: MailThread) throws {
            upsertCount += 1
            try inner.upsertThread(thread)
        }
        func accounts() -> [MailAccount] { inner.accounts() }
        func saveAccount(_ account: MailAccount) throws { try inner.saveAccount(account) }
        func removeAccount(_ id: String) throws { try inner.removeAccount(id) }
        func purge(accountID: String) throws { try inner.purge(accountID: accountID) }
        func summaries(accountID: String, months: [String]) -> [ThreadSummary] {
            inner.summaries(accountID: accountID, months: months)
        }
        func thread(_ id: String) -> MailThread? { inner.thread(id) }
        func removeThread(_ id: String, accountID: String, date: Date) throws {
            try inner.removeThread(id, accountID: accountID, date: date)
        }
        func body(messageID: String) -> MessageBody? { inner.body(messageID: messageID) }
        func saveBody(_ body: MessageBody, accountID: String) throws {
            try inner.saveBody(body, accountID: accountID)
        }
        func labels(accountID: String) -> [MailLabel] { inner.labels(accountID: accountID) }
        func saveLabels(_ labels: [MailLabel], accountID: String) throws {
            try inner.saveLabels(labels, accountID: accountID)
        }
    }

    /// Collects one provider call's outcome **with a deadline**, so an unanswered
    /// command fails the test instead of hanging the suite — the same reason
    /// `IMAPAuthHarness.boundedOutcome` exists, and none of the suites here may await
    /// a provider bare.
    ///
    /// The budget is 10 seconds rather than that helper's 2, and the difference is
    /// not carelessness. `boundedOutcome`'s 2s is calibrated for ONE scripted command;
    /// a single provider call here chains five or more (`SELECT`, `UID SEARCH`,
    /// `UID FETCH`, `SELECT`, `UID STORE`…) and the applyLabels tests make two such
    /// calls. At 2s those tests failed intermittently on a loaded machine — a flake
    /// that is worse than a slow test in both directions: it fails clean code, and a
    /// mutation sweep reads the noise as a kill. A deadline still bounds the hang;
    /// only its size changed, and no passing test waits for it.
    private static func outcome<T: Sendable>(
        _ label: String, sourceLocation: SourceLocation,
        _ body: @escaping @Sendable () async throws -> T) async -> Result<T, any Error>? {
        let box = ProviderOutcomeBox<T>()
        let task = Task {
            do { await box.set(.success(try await body())) }
            catch { await box.set(.failure(error)) }
        }
        for _ in 0..<1_000 {
            if let value = await box.value { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        Issue.record("\(label) never resolved within 10s — the leaked-continuation shape",
                     sourceLocation: sourceLocation)
        return nil
    }

    private actor ProviderOutcomeBox<T: Sendable> {
        private(set) var value: Result<T, any Error>?
        func set(_ value: Result<T, any Error>) {
            if self.value == nil { self.value = value }
        }
    }

    /// Asserts a provider call succeeded within the deadline, and returns its value.
    static func expect<T: Sendable>(_ label: String,
                                    sourceLocation: SourceLocation = #_sourceLocation,
                                    _ body: @escaping @Sendable () async throws -> T) async -> T? {
        guard let outcome = await outcome(label, sourceLocation: sourceLocation, body)
        else { return nil }
        switch outcome {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("\(label) failed: \(error)", sourceLocation: sourceLocation)
            return nil
        }
    }

    /// Asserts a provider call threw, within the deadline.
    static func expectFailure<T: Sendable>(_ label: String,
                                           sourceLocation: SourceLocation = #_sourceLocation,
                                           _ body: @escaping @Sendable () async throws -> T) async
        -> (any Error)? {
        guard let outcome = await outcome(label, sourceLocation: sourceLocation, body)
        else { return nil }
        switch outcome {
        case .success:
            Issue.record("\(label) was expected to fail but succeeded",
                         sourceLocation: sourceLocation)
            return nil
        case .failure(let error): return error
        }
    }
}
