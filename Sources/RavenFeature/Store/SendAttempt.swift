import Foundation

/// What became of one queued outbox operation, as far as anyone outside the
/// outbox can honestly tell.
public enum OutboxSendOutcome: Equatable, Sendable {
    /// The provider accepted it and the entry left the queue. The ONLY
    /// outcome on which a draft may be destroyed.
    case sent
    /// Still queued — either waiting for the next pass, or handed to the
    /// provider by a drain that has not returned yet. Not a failure, but
    /// emphatically not a success either.
    case queued(inFlight: Bool)
    /// Retried to exhaustion and given up on. A human must resolve it.
    case deadLettered(lastError: String?)
    /// A previous process died mid-operation; whether it reached the provider
    /// is unknown, so it is held rather than guessed at.
    case needsReview

    public var isSent: Bool { self == .sent }
}

/// The one place that turns "the user asked to send this" into an outcome.
///
/// Both the human path (`ComposeSurface`'s Send button) and the agent path
/// (`RavenMCPOperations.send_draft`) go through here. They used to each decide
/// for themselves what a send meant, and they drifted: the MCP path was fixed
/// to check the entry's real fate while the UI path kept destroying the draft
/// unconditionally. Sending is the one irreversible operation in this app, so
/// the decision lives in exactly one function that both callers must use.
///
/// The invariant, in one line: **the draft is removed if and only if the
/// outcome is `.sent`.**
@MainActor
public enum SendAttempt {
    public struct Result: Sendable {
        public let outcome: OutboxSendOutcome
        /// User-facing explanation, safe to show in the composer banner or
        /// return as an MCP tool result. Never contains message body text.
        public let message: String
        public var isSent: Bool { outcome.isSent }
    }

    /// Queues `message`, drains once, and reports what actually happened.
    /// Removes `draftID` from `DraftBox` only on `.sent`.
    ///
    /// - Parameter drain: how to run the drain. `ComposeSurface` passes
    ///   `runtime.drainOutbox` so the dead-letter/needs-review snapshots the
    ///   Accounts surface renders are refreshed too; the MCP path passes
    ///   `outbox.drain`. Neither may throw — failures land on the entries.
    /// - Throws: only if `enqueue` itself could not persist the queue. In that
    ///   case nothing was sent and the draft is untouched.
    @discardableResult
    public static func send(_ message: OutgoingMessage, draftID: String?,
                            outbox: Outbox,
                            drain: () async -> Void) async throws -> Result {
        let entryID = try outbox.enqueue(.send(message))
        await drain()
        let outcome = outbox.outcome(for: entryID)
        if outcome.isSent, let draftID {
            DraftBox.shared.remove(draftID)
        }
        return Result(outcome: outcome, message: describe(outcome, draftID: draftID))
    }

    /// Shared wording, so the composer banner and the agent's tool result say
    /// the same thing about the same situation.
    public static func describe(_ outcome: OutboxSendOutcome, draftID: String?) -> String {
        let subject = draftID.map { "draft \($0)" } ?? "the message"
        switch outcome {
        case .sent:
            return "Sent \(subject)."
        case .queued(let inFlight):
            return inFlight
                ? "\(subject.prefix(1).uppercased() + subject.dropFirst()) has been handed to "
                    + "the server but has not been confirmed yet; it is still in the outbox and "
                    + "the draft was kept. Check Accounts before resending."
                : "\(subject.prefix(1).uppercased() + subject.dropFirst()) is queued and will "
                    + "retry automatically; it has not gone out yet. The draft was kept."
        case .deadLettered(let lastError):
            return "Sending \(subject) failed after repeated attempts"
                + (lastError.map { ": \($0)" } ?? "")
                + ". The draft was kept — resolve or discard the failed send in Accounts "
                + "before trying again."
        case .needsReview:
            return "The outcome of sending \(subject) is unknown — the app may have quit "
                + "mid-send. The draft was kept; confirm in Accounts whether it actually "
                + "went out before resending."
        }
    }
}
