import Foundation

/// Owns the one `DraftBox` entry a composing session writes to, and the guard
/// that stops a late write from resurrecting a draft a send has already removed.
///
/// **Why this exists.** An unsent draft's survival used to rest on
/// `ComposeSurface.onDisappear` firing when the kit's modal tore its content
/// down — a view-lifecycle callback, i.e. incidental. This project has already
/// lost drafts twice from exactly that class of bug (a failed send deleting the
/// draft; `outcome(for:)` inferring success from an entry's absence), and both
/// were fixed by making the guarantee structural. So the draft is now written as
/// it is edited: dismissing, crashing, or the kit changing how it tears content
/// down all converge on "the text is already saved". `onDisappear` remains only
/// as a final flush, and is no longer what the guarantee depends on.
///
/// **Why the generation counter.** The autosave is debounced, so a write can
/// still be in flight when Send removes the draft — and a write that lands after
/// that removal is a ghost draft for a message that has already gone out,
/// breaking "a draft is removed if and only if the message was sent". Every
/// caller reads `generation` BEFORE it starts waiting and passes it back to
/// `save`; `retire()` (called once the send has removed the draft) bumps the
/// counter, so any write scheduled before the send is refused rather than
/// re-creating the entry. The ordering is enforced here rather than left to
/// whoever happens to call in what order.
///
/// `DraftBox` is injected rather than reached for via `.shared` so this is
/// testable against a fresh box.
@MainActor public final class ComposeDraftKeeper {
    private let box: DraftBox

    /// The single entry this session writes to, or `nil` before the first save
    /// (and again after `retire()`). One entry per composing session — never a
    /// new draft per autosave tick.
    public private(set) var draftID: String?

    /// Bumped by `retire()`. A `save` carrying an older value is refused.
    public private(set) var generation = 0

    public init(box: DraftBox = .shared, draftID: String? = nil) {
        self.box = box
        self.draftID = draftID
    }

    /// Points this session at an existing draft — the rail loading one, or
    /// `undoSend` restoring a cancelled message. Subsequent autosaves update
    /// that entry instead of forking a second copy of the same message.
    public func adopt(_ id: String?) {
        draftID = id
    }

    /// Writes `message` through to the session's entry, creating it on the
    /// first call and updating it thereafter.
    ///
    /// Refuses, and returns `nil`, when `generation` is stale — meaning a send
    /// has retired this session since the caller decided to save.
    @discardableResult
    public func save(_ message: OutgoingMessage, generation: Int) -> String? {
        guard generation == self.generation else { return nil }
        guard let id = try? box.save(message, id: draftID) else { return nil }
        draftID = id
        return id
    }

    /// Called once a send has taken responsibility for the draft: after
    /// `SendAttempt` removed it on `.sent`, or after the caller removed it
    /// because the message is held on an outbox entry instead.
    ///
    /// Detaches from the id AND invalidates anything already scheduled, so the
    /// next edit starts a genuinely new draft and no in-flight write can bring
    /// the sent one back.
    public func retire() {
        draftID = nil
        generation += 1
    }
}
