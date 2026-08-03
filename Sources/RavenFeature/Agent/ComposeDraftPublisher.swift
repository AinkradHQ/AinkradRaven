import Foundation
import Observation

/// The bridge between the composer on screen and Sage.
///
/// Two directions, deliberately kept in one place so they cannot drift:
///
/// - **Out.** `openDraft` is whatever the composer currently holds. It is what
///   makes "make this more formal", "shorten this" and "is this too blunt?"
///   answerable: without it, Sage's mail context is the *selected thread*, so
///   asking it to rewrite the reply you are looking at gets a rewrite of the
///   message you are replying TO.
/// - **In.** `requestedPrefill` is a draft Sage has written and handed back for
///   the user to review. `RavenShell` opens the composer on it; `ComposeSurface`
///   consumes it exactly once.
///
/// **This publishes; it never calls a model.** Raven ships zero model calls and
/// that is not incidental — a plugin that reaches a model directly is a plugin
/// whose token spend, prompt and data egress the host cannot see. Everything
/// here is a value handed across the boundary.
///
/// Not `Codable` and not persisted: an in-flight draft's home is `DraftBox` (via
/// the autosave), and a second persistence path for the same text is how the
/// "draft removed iff sent" invariant gets broken.
@MainActor
@Observable
public final class ComposeDraftPublisher {
    /// One per process. The composer is a single overlay and there is exactly
    /// one open draft at a time, so an instance per host would just be a way
    /// for the bridge to read a different one than the composer wrote.
    public static let shared = ComposeDraftPublisher()

    /// The draft currently in the composer, or `nil` when the composer is
    /// closed or empty. `nil` rather than a blank message on purpose: Sage
    /// seeing an empty draft as context would answer "shorten this" about
    /// nothing.
    public private(set) var openDraft: OutgoingMessage?

    /// A draft Sage wants the user to review, not send. Cleared by
    /// `consumeRequestedPrefill()`.
    public private(set) var requestedPrefill: OutgoingMessage?

    public init() {}

    /// Called by the composer on every meaningful edit, and with `nil` on
    /// teardown. Ignores a message with nothing in it so a composer that was
    /// opened and not typed into does not become context.
    public func publish(_ message: OutgoingMessage?) {
        guard let message, Self.isWorthPublishing(message) else {
            openDraft = nil
            return
        }
        openDraft = message
    }

    /// Whether a draft has enough in it to be worth putting in front of an
    /// agent — any recipient, or any non-whitespace subject or body.
    static func isWorthPublishing(_ message: OutgoingMessage) -> Bool {
        if !message.to.isEmpty || !message.cc.isEmpty || !message.bcc.isEmpty { return true }
        if !message.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !message.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func request(prefill message: OutgoingMessage) {
        requestedPrefill = message
    }

    /// Hands the pending request over and clears it, so a prefill can never be
    /// applied twice — the composer's `prefillIfNeeded` runs from a `.task`
    /// that a re-render could otherwise re-enter.
    public func consumeRequestedPrefill() -> OutgoingMessage? {
        defer { requestedPrefill = nil }
        return requestedPrefill
    }
}
