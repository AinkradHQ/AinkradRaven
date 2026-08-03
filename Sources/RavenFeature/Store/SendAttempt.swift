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
    /// The entry left the queue without any record of having been
    /// transmitted — it was purged by a sign-out, or discarded, while the
    /// send was still in progress. NOT a success: nothing was sent.
    case removedWithoutSending

    public var isSent: Bool { self == .sent }

    /// True when nothing went wrong and the operation is simply not finished.
    /// Used to style the composer banner: a red "error" for a benign queued
    /// send invites the user to press Send again, which enqueues a SECOND
    /// message that will also transmit.
    public var isBenign: Bool {
        if case .queued = self { return true }
        return false
    }
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
        /// The outbox entry this attempt queued. Exposed so a caller that
        /// enqueued a HELD send (undo-send window) can offer a cancel
        /// affordance keyed to this exact entry, via `Outbox.cancelHeld`.
        public let entryID: UUID
        public var isSent: Bool { outcome.isSent }
    }

    /// Default undo-send hold window: how long a just-queued send stays
    /// cancelable — via `Outbox.cancelHeld` — before `Outbox.drain()` is
    /// allowed to actually transmit it. Twenty seconds: the middle of the
    /// commonly-recommended 10-30s undo-send range, erring toward giving a
    /// real chance to catch a mistake without "Send" feeling sluggish.
    ///
    /// Applied identically to BOTH the human Send button (`ComposeSurface`)
    /// and the agent's `send_draft` (`RavenMCPOperations`) — see the doc
    /// comment on the `send_draft` case in `RavenMCPOperations.run` for why:
    /// in short, Sage's own human-approval gate happens before `send_draft`
    /// is even called, so it is not a substitute for this window, and giving
    /// Sage's sends a SHORTER or absent hold would mean approving one of
    /// Sage's sends transmits FASTER than the user's own Send button — the
    /// opposite of the surprise this window exists to prevent.
    public static let defaultHoldWindow: TimeInterval = 20

    /// Queues `message`, drains once, and reports what actually happened.
    /// Removes `draftID` from `DraftBox` only on `.sent`.
    ///
    /// This is also the one place the account signature is applied — both
    /// the UI compose path and the MCP `create_draft`/`send_draft` path call
    /// this function (see the type's own documentation for why sending lives
    /// in exactly one place), so appending it here, rather than in
    /// `ComposeSurface` or `RavenMCPOperations`, is the only way both routes
    /// genuinely share it instead of one of them silently missing it. `store`
    /// is looked up by `outbox.accountID` — the account the message is about
    /// to transmit through — and an empty or missing signature appends
    /// nothing at all (no stray `\n-- \n` with nothing after it).
    ///
    /// - Parameter drain: how to run the drain. `ComposeSurface` passes
    ///   `runtime.drainOutbox` so the dead-letter/needs-review snapshots the
    ///   Accounts surface renders are refreshed too; the MCP path passes
    ///   `outbox.drain`. Neither may throw — failures land on the entries.
    /// - Throws: only if `enqueue` itself could not persist the queue. In that
    ///   case nothing was sent and the draft is untouched.
    /// - Parameter holdUntil: when set, `Outbox.pending()` will not transmit
    ///   this entry until this timestamp — the undo-send window. Defaults to
    ///   `nil` (immediate, non-cancelable send) so every EXISTING caller and
    ///   test that does not pass this keeps its current, pre-M3 behavior
    ///   unchanged. The two real send surfaces (`ComposeSurface.send`,
    ///   `RavenMCPOperations`'s `send_draft`) explicitly pass
    ///   `Date().addingTimeInterval(SendAttempt.defaultHoldWindow)` (or the
    ///   user's configured window) — see each call site.
    /// - Parameter sendAt: an additional, independent future time (scheduled
    ///   send) the entry must also wait for. `nil` (the default) means "no
    ///   scheduling — only the hold window, if any, applies".
    @discardableResult
    public static func send(_ message: OutgoingMessage, draftID: String?,
                            outbox: Outbox, store: MailStore,
                            holdUntil: Date? = nil,
                            sendAt: Date? = nil,
                            drain: () async -> Void) async throws -> Result {
        let message = withSignature(message, outbox: outbox, store: store)
        let entryID = try outbox.enqueue(.send(message), accountID: nil,
                                         holdUntil: holdUntil, sendAt: sendAt, draftID: draftID)
        await drain()
        let outcome = outbox.outcome(for: entryID)
        if outcome.isSent, let draftID {
            DraftBox.shared.remove(draftID)
        }
        return Result(outcome: outcome, message: describe(outcome, draftID: draftID), entryID: entryID)
    }

    /// Conventional signature separator (sigdash) — a line consisting of
    /// exactly `-- ` (dash dash space), which mail clients treat specially
    /// (e.g. trimming it on reply). Only ever written when there is a
    /// non-empty signature to follow it.
    ///
    /// Shared with `MarkdownToHTML.renderComposed` via `Signature`, which
    /// splits it back off before Markdown parsing — `--` is a valid setext h2
    /// underline, so a parser handed the concatenated string turns the body's
    /// last line into a heading and eats the separator.
    private static let sigdash = Signature.sigdash

    /// Appends the account's signature to `message.bodyText`, or returns
    /// `message` unchanged if the account is unknown or its signature is
    /// empty. Never mutates `message.subject`, addressing, or threading —
    /// only the body.
    private static func withSignature(_ message: OutgoingMessage, outbox: Outbox,
                                      store: MailStore) -> OutgoingMessage {
        // The message's OWN account first: with several accounts connected,
        // `outbox.accountID` is only a default stamp, so trusting it would
        // sign mail from account A with account B's signature.
        guard let accountID = message.accountID ?? outbox.accountID,
              let account = store.accounts().first(where: { $0.id == accountID }),
              !account.signature.isEmpty else { return message }
        return OutgoingMessage(to: message.to, cc: message.cc, subject: message.subject,
                               bodyText: message.bodyText + sigdash + account.signature,
                               inReplyToMessageID: message.inReplyToMessageID,
                               threadID: message.threadID,
                               accountID: message.accountID)
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
        case .removedWithoutSending:
            return "\(subject.prefix(1).uppercased() + subject.dropFirst()) was removed from "
                + "the outbox before it could be sent — the account was signed out, or the "
                + "queued send was discarded. Nothing was transmitted and the draft was kept."
        }
    }
}
