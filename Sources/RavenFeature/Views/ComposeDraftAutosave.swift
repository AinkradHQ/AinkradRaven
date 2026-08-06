import SwiftUI
import AinkradAppKit

/// `ComposeSurface`'s prefill and draft-persistence half.
///
/// Split out purely to keep both files under the 500-line cap — `ComposeSurface`
/// crossed it once the compose overlay's layout gained its two-column structure.
/// Nothing here changed in the move except access level: the members are
/// `internal` rather than `private` because an extension in a different file
/// cannot see `private` ones. They are still only reachable inside this module,
/// and the two invariants they carry are unchanged — the autosave is the draft
/// survival guarantee (`onDisappear` is only a flush), and every write goes
/// through `ComposeDraftKeeper`'s generation guard so a save cannot land after a
/// send has removed the draft.
extension ComposeSurface {
    // MARK: Prefill and draft preservation

    /// Fills the fields from `ReplyComposer` for a reply/forward. Runs once —
    /// `didPrefill` guards it — because the overlay's body re-runs on every
    /// keystroke and re-prefilling would erase what was typed.
    func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true
        // A draft Sage handed back via the `open_compose` action takes
        // precedence over a reply prefill, because the two cannot both apply:
        // the shell only raises this overlay with a pending request when there
        // is one, and the request already carries whatever recipients and body
        // the agent wrote. Consumed once — see
        // `ComposeDraftPublisher.consumeRequestedPrefill`.
        if let requested = ComposeDraftPublisher.shared.consumeRequestedPrefill() {
            toChips = requested.to.map { RecipientChip(raw: rfc5322(for: $0)) }
            ccChips = requested.cc.map { RecipientChip(raw: rfc5322(for: $0)) }
            bccChips = requested.bcc.map { RecipientChip(raw: rfc5322(for: $0)) }
            subject = requested.subject
            bodyText = requested.bodyText
            return
        }
        guard case .reply(let mode, let reference) = context,
              let thread = runtime.store.thread(reference.threadID),
              let last = thread.messages.last else { return }
        let body = runtime.store.body(messageID: last.id)?.plainText ?? ""
        let draft = ReplyComposer.compose(
            mode: mode, thread: thread, lastMessage: last, lastMessageBody: body,
            // The replying account is the thread's own, not "the" account:
            // excluding the wrong address from a reply-all mails the user
            // their own mailbox.
            ownAddress: runtime.ownAddress(for: reference.accountID))
        toChips = draft.to.map { RecipientChip(raw: rfc5322(for: $0)) }
        subject = draft.subject
        bodyText = draft.bodyText
    }

    /// How long after the last edit the draft is written. Long enough that
    /// typing a sentence is one write, short enough that "I typed it, then the
    /// overlay went away" is never a lost message.
    static let autosaveDelay: Duration = .milliseconds(600)

    /// The digest `.task(id:)` watches. Every editable field is in it, so any
    /// change restarts the debounce, and nothing else is, so an unrelated
    /// re-render (a hover, a drafts-list refresh) does not schedule a write.
    ///
    /// Recipient chips contribute their raw text rather than their parsed
    /// address: a half-typed recipient is still an edit worth saving.
    var autosaveKey: String {
        // Bcc is in the digest for the same reason To and Cc are, and it matters
        // more: a blind recipient dropped by a draft that did not notice it
        // changed is invisible in the message that goes out.
        [toChips.map(\.raw).joined(separator: ","),
         ccChips.map(\.raw).joined(separator: ","),
         bccChips.map(\.raw).joined(separator: ","),
         subject,
         bodyText,
         attachments.map(\.filename).joined(separator: ","),
         selectedFromAccountID ?? ""].joined(separator: "\u{1F}")
    }

    /// Writes the draft `autosaveDelay` after the last edit.
    ///
    /// The generation is read BEFORE the sleep, deliberately: if a send retires
    /// the session while this is waiting, `ComposeDraftKeeper.save` refuses the
    /// stale write rather than re-creating a draft for a message that has already
    /// gone out. That ordering is the whole reason the counter exists.
    func autosave() async {
        guard hasContent else { return }
        let generation = keeper.generation
        draftStateText = "Saving\u{2026}"
        try? await Task.sleep(for: Self.autosaveDelay)
        // Cancelled means another keystroke landed and a NEW autosave task is
        // already showing "Saving…" — leaving the text alone here is what keeps
        // it from flickering back to "Draft saved" mid-sentence.
        guard !Task.isCancelled else { return }
        if keeper.save(stampedMessage(), generation: generation) != nil {
            draftStateText = "Draft saved"
            // So the rail shows the draft appearing as it is typed.
            draftsVersion += 1
        } else {
            // The generation guard refused the write — the session was retired
            // by a send. Saying "Draft saved" here would claim a draft exists
            // for a message that has already left.
            draftStateText = nil
        }
    }

    /// A final flush for an edit made inside the debounce window, nothing more.
    ///
    /// This used to BE the persistence guarantee, which made an unsent draft's
    /// survival depend on SwiftUI calling `onDisappear` when the kit's modal tore
    /// its content down — incidental, and the same bug class that has already
    /// lost drafts in this app twice. The autosave above is the guarantee now; if
    /// this never ran, at most the last 600ms of typing would be missing.
    ///
    /// It is a SAVE, never a delete, and it goes through the same keeper, so it
    /// cannot resurrect a retired draft either.
    func preserveDraft() {
        guard hasContent else { return }
        keeper.save(stampedMessage(), generation: keeper.generation)
    }

    /// Whether there is anything worth keeping. Deliberately strict about
    /// emptiness so opening the composer and immediately closing it does not
    /// litter the drafts list with blanks.
    var hasContent: Bool {
        !toChips.isEmpty || !ccChips.isEmpty || !bccChips.isEmpty || !attachments.isEmpty
            || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
