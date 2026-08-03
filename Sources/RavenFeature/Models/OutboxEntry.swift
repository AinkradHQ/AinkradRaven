import Foundation

public struct OutboxEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Operation: Codable, Equatable, Sendable {
        case labels(LabelMutation)
        case send(OutgoingMessage)
    }

    public let id: UUID
    public let operation: Operation
    public var attempts: Int
    public var lastError: String?
    public var isDeadLettered: Bool
    public let queuedAt: Date
    /// Set immediately before the operation is handed to the provider, and
    /// persisted before the call is made. If a fresh process finds this set on
    /// load, the previous process died mid-operation and the outcome (did the
    /// email actually go out?) is unknown — see `Outbox`'s init for how that is
    /// handled.
    public var inFlightAt: Date?
    /// True when this entry's outcome is unknown (see `inFlightAt`) and it has
    /// been pulled out of `pending()` for a human to resolve, rather than being
    /// guessed at automatically.
    public var needsReview: Bool
    /// The account this operation belongs to, stamped by `Outbox.enqueue` from
    /// the outbox's current account. `OutgoingMessage` itself carries no
    /// account, so without this a send queued while account A was connected
    /// would transmit from account B the moment a different account signed in
    /// — the wrong mailbox, and irreversible for a `.send`. `nil` means
    /// "queued before any account was known"; those stay eligible, since there
    /// is no account they could be crossing over from.
    public var accountID: String?
    /// Undo-send window: while `Date() < holdUntil`, `Outbox.pending()` skips
    /// this entry and `Outbox.cancelHeld` may pull it back out as an editable
    /// draft. Persisted (not a `Task.sleep`) so a crash-and-restart preserves
    /// the remaining hold exactly — see `SendAttempt.defaultHoldWindow` for
    /// the default duration and why it applies to both the human Send button
    /// and the agent `send_draft` path.
    public var holdUntil: Date?
    /// User-chosen future send time (scheduled send). Like `holdUntil`, a
    /// persisted timestamp `Outbox.pending()` gates on — never a sleep — so
    /// the scheduled time survives a relaunch. Distinct from `holdUntil`
    /// semantically (one is an auto-applied cancel window, the other a
    /// deliberate future time) even though both currently share one
    /// eligibility check (`isEligible`).
    public var sendAt: Date?
    /// The `DraftBox` id this `.send` came from, if any. Carried on the entry
    /// itself (not just handled at enqueue time by `SendAttempt`) so that when
    /// a HELD or SCHEDULED send finally transmits — potentially long after
    /// the `SendAttempt.send` call that queued it returned — `Outbox.drain()`
    /// can still remove the right draft. Without this, only an immediate
    /// (un-held) send's draft was ever cleaned up.
    public var draftID: String?

    public init(id: UUID = UUID(), operation: Operation, attempts: Int = 0,
                lastError: String? = nil, isDeadLettered: Bool = false,
                queuedAt: Date = Date(), inFlightAt: Date? = nil,
                needsReview: Bool = false, accountID: String? = nil,
                holdUntil: Date? = nil, sendAt: Date? = nil, draftID: String? = nil) {
        self.id = id; self.operation = operation; self.attempts = attempts
        self.lastError = lastError; self.isDeadLettered = isDeadLettered
        self.queuedAt = queuedAt; self.inFlightAt = inFlightAt
        self.needsReview = needsReview; self.accountID = accountID
        self.holdUntil = holdUntil; self.sendAt = sendAt; self.draftID = draftID
    }

    /// Whether this entry may transmit yet, as of `now`. Both `holdUntil`
    /// (the undo-send window) and `sendAt` (a scheduled future time) gate the
    /// same way — neither elapsed means neither may fire yet — even though
    /// they are set for different reasons; see their own documentation.
    public func isEligible(now: Date = Date()) -> Bool {
        if let holdUntil, now < holdUntil { return false }
        if let sendAt, now < sendAt { return false }
        return true
    }
}
