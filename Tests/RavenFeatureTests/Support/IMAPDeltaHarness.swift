import Testing
import Foundation
@testable import RavenFeature

/// The scripted server and the injected identity that `IMAPDeltaStrategyTests`
/// drives both delta paths with.
///
/// Split out of the suite for the repo's 500-line limit, the same way
/// `IMAPSessionHarness` and `IMAPAuthHarness` were, and for the same second
/// reason: the CONDSTORE path and the fallback path must be handed the **same**
/// `IMAPDeltaIdentity` value, so it cannot live file-private in a suite that
/// tests only one of them.
enum IMAPDeltaHarness {

    // MARK: - The scripted mailbox
    //
    // One mailbox, three simultaneous kinds of change, chosen so a plausible
    // wrong implementation of EITHER path yields a DIFFERENT delta:
    //
    // - UID 10: an OLD message whose flags changed (`\Seen` added). Only a
    //   `CHANGEDSINCE` fetch or a full flag re-scan finds it. A fallback that
    //   walks arrivals alone misses it.
    // - UID 11: an OLD message that did NOT change. A fallback that reports its
    //   whole re-scan as changed includes it.
    // - UID 12: REMOVED. Reported as `VANISHED (EARLIER)` on the fast path and as
    //   "known, in range, absent from the re-scan" on the slow one.
    // - UID 20: an ARRIVAL. Its thread id can only come from the fetched
    //   envelope, since no stored UID exists for it.

    static let mailbox = "Folder A"

    /// The stored position both paths start from: generation 1, everything below
    /// UID 20 walked, `HIGHESTMODSEQ 100` observed.
    static func storedCursor(highestModSeq: UInt64? = 100) -> IMAPSyncCursor {
        IMAPSyncCursor(mailboxes: [
            mailbox: IMAPMailboxSyncState(uidValidity: 1, uidNext: 20,
                                          highestModSeq: highestModSeq),
            // A second mailbox, present only so "a UIDVALIDITY change resets one
            // mailbox and no other" is assertable.
            "Folder B": IMAPMailboxSyncState(uidValidity: 9, uidNext: 5,
                                            highestModSeq: 55),
        ])
    }

    /// Thread ids for the UIDs this client already holds.
    static let storedThreadIDs: [UInt32: String] = [10: "t-a", 11: "t-b", 12: "t-c"]
    /// `Message-ID` → thread id, i.e. what Task 13's assembler will compute.
    static let threadIDsByMessageID: [String: String] = [
        "m1@example.test": "t-a", "m2@example.test": "t-b",
        "m3@example.test": "t-c", "m4@example.test": "t-d",
    ]
    /// The flags last stored. Every held message was unread.
    static let storedFlags: [UInt32: Set<MailFlag>] = [
        10: [.unread], 11: [.unread], 12: [.unread],
    ]

    /// The one resolver both paths get. Nothing here knows which walk is running.
    static func identity(
        mailbox: String = IMAPDeltaHarness.mailbox,
        sequenceNumbers: [UInt64: UInt32] = [:]
    ) -> IMAPDeltaIdentity {
        IMAPDeltaIdentity(
            mailbox: mailbox,
            knownUIDs: { Set(storedThreadIDs.keys) },
            knownFlags: { storedFlags[$0] },
            threadID: { storedThreadIDs[$0] },
            threadIDForFetched: { fetched in
                fetched.envelope?.messageID.flatMap { threadIDsByMessageID[$0] }
            },
            uidForSequenceNumber: { sequenceNumbers[$0] })
    }

    // MARK: - Scripting

    /// One scripted exchange: a substring the client's command must contain, and
    /// the untagged lines the server answers with.
    ///
    /// A command that does not match any step gets **no answer**, so a wrong
    /// command surfaces as a bounded-deadline failure rather than as a
    /// plausible-looking delta computed from the wrong bytes.
    struct Step {
        let needle: String
        /// Fixture base name, or nil for a command answered with the completion
        /// only.
        let fixture: String?
        /// Completion status. `.no` scripts the transient mid-delta failure.
        let status: String

        init(_ needle: String, _ fixture: String? = nil, status: String = "OK") {
            self.needle = needle
            self.fixture = fixture
            self.status = status
        }
    }

    /// A fixture's bytes, byte-for-byte. CRLF-exact, `-text` in `.gitattributes`,
    /// so no newline translation happens on either side of the blob.
    static func fixtureText(_ name: String) throws -> String {
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: name, withExtension: "txt"),
            "fixture \(name).txt is not in the test bundle — run `xcodegen generate`")
        let data = try Data(contentsOf: url)
        return try #require(String(data: data, encoding: .utf8))
    }

    /// A connected session whose capabilities come from the greeting, so no
    /// `CAPABILITY` command is issued and the tags the steps answer with are
    /// exactly `A0001…A000n` in step order.
    static func session(capabilities: String, steps: [Step]) async throws
        -> (IMAPSession, ScriptedTransport) {
        let transport = ScriptedTransport(idleReads: .suspend)
        await transport.enqueue("* OK [CAPABILITY \(capabilities)] ready\r\n")
        for (index, step) in steps.enumerated() {
            var response = ""
            if let fixture = step.fixture { response += try fixtureText(fixture) }
            response += String(format: "A%04d", index + 1) + " \(step.status) done\r\n"
            await transport.respond(to: step.needle, with: response)
        }
        let session = IMAPSession(transport: transport)
        try await session.connect()
        return (session, transport)
    }

    // MARK: - Running a pass

    /// A delta plus the cursor the pass left behind — both needed, since
    /// hold-vs-advance is a property of the cursor and not of the delta.
    struct PassResult: Sendable {
        let delta: MailDelta
        let cursor: IMAPSyncCursor
    }

    /// Runs one pass **with a deadline**. A strategy that never resolves is the
    /// leaked-continuation shape, and a hung suite reports as an infrastructure
    /// timeout rather than as the bug it is.
    static func pass(_ strategy: IMAPDeltaStrategy, from cursor: IMAPSyncCursor,
                     sourceLocation: SourceLocation = #_sourceLocation) async
        -> Result<PassResult, any Error>? {
        await boundedOutcome(sourceLocation: sourceLocation) {
            var working = cursor
            // The mailbox is not passed: it travels inside the identity, so a
            // suite cannot pair one mailbox's UID table with another's walk.
            // See `IMAPDeltaIdentity.mailbox`.
            let delta = try await strategy.delta(cursor: &working)
            return PassResult(delta: delta, cursor: working)
        }
    }

    /// Holds a cursor across a bounded pass so `inout` is exercised for real.
    ///
    /// Needed because the hold-vs-advance property is about what the strategy did
    /// to the CALLER's cursor, and a `var` local cannot be captured by the
    /// `@Sendable` closure the deadline helper takes. Passing `&cursor` from
    /// inside the actor's own isolated method is the same `inout` call a provider
    /// will make.
    actor CursorBox {
        private(set) var cursor: IMAPSyncCursor
        init(_ cursor: IMAPSyncCursor) { self.cursor = cursor }
        /// The local `working` copy is written back **whether the pass throws or
        /// not**, so the box reports exactly what the strategy left in the
        /// variable it was handed. A strategy that advanced the cursor before
        /// failing is therefore visible here rather than hidden by the rethrow —
        /// which is the whole point of the hold-vs-advance assertion.
        func run(_ strategy: IMAPDeltaStrategy) async throws -> MailDelta {
            var working = cursor
            // An actor's own property cannot be passed `inout` to an `async` call,
            // so the copy is forced by the language, not chosen.
            defer { cursor = working }
            return try await strategy.delta(cursor: &working)
        }
    }

    /// Asserts a pass succeeded within the deadline.
    static func expectPass(_ strategy: IMAPDeltaStrategy, from cursor: IMAPSyncCursor,
                           sourceLocation: SourceLocation = #_sourceLocation) async
        -> PassResult? {
        guard let outcome = await pass(strategy, from: cursor,
                                       sourceLocation: sourceLocation) else { return nil }
        switch outcome {
        case .success(let result): return result
        case .failure(let error):
            Issue.record("expected the delta pass to succeed but it failed: \(error)",
                         sourceLocation: sourceLocation)
            return nil
        }
    }
}
