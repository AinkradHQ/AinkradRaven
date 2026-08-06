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

    // MARK: Drafts rail, loading and clearing

    /// Moved here from `ComposeSurface` when the rich editor arrived: that file
    /// had to get SMALLER, not larger, and this half — the rail, loading a
    /// saved draft, emptying the composer, and pulling a held send back out of
    /// the outbox — is the same draft-session concern the rest of this file
    /// already owns. Nothing changed in the move except access level (an
    /// extension in another file cannot see `private` members).
    // MARK: Drafts rail

    /// The width the rail earns when it is shown. Matches
    /// `RavenShell.draftsRailMinWidth`'s assumption about what a rail costs.
    static let draftsRailWidth: CGFloat = 220

    /// Whether the second column exists.
    ///
    /// Two conditions, both necessary. The shell's width threshold
    /// (`showsDraftsRail`) is unchanged. The new one is "there is at least one
    /// saved draft": a rail whose entire content was a sentence explaining that
    /// nothing is saved yet cost 220pt of the composer's width to say nothing,
    /// and it was the emptiest possible version of it — a brand-new message —
    /// that the user was looking at. No drafts, no column; the first autosave
    /// (600ms into typing) brings it in, and `draftsVersion` is already bumped
    /// on every draft mutation so this re-evaluates then.
    var showsRail: Bool { showsDraftsRail && savedDraftCount > 0 }

    /// Read through `draftsVersion` for the same reason `ComposeDraftsRail`
    /// does: `DraftBox` is a plain in-memory box, not observable.
    var savedDraftCount: Int {
        _ = draftsVersion
        return DraftBox.shared.all().count
    }

    var draftList: some View {
        ComposeDraftsRail(
            version: draftsVersion,
            selectedDraftID: keeper.draftID,
            onSelect: load,
            onDelete: { id in
                DraftBox.shared.remove(id)
                // Deleting the draft being edited retires the session too, so the
                // pending autosave cannot immediately write it back.
                if keeper.draftID == id { keeper.retire(); clear() }
                draftsVersion += 1
            })
    }

    /// Loads a saved draft into the composer, INCLUDING whatever conversation
    /// it belonged to. A draft persisted from a dismissed reply carries
    /// `threadID`/`inReplyToMessageID`/`accountID` on its `OutgoingMessage`, so
    /// resuming it restores a reply rather than silently demoting it to a new
    /// message that would land outside the thread.
    func load(_ id: String, _ message: OutgoingMessage) {
        // Autosaves from here on update THIS entry rather than forking a copy.
        keeper.adopt(id)
        toChips = message.to.map { RecipientChip(raw: rfc5322(for: $0)) }
        ccChips = message.cc.map { RecipientChip(raw: rfc5322(for: $0)) }
        bccChips = message.bcc.map { RecipientChip(raw: rfc5322(for: $0)) }
        subject = message.subject
        // The draft's formatting comes back with it; a draft written before
        // M6 (or by any plain producer) has none, and restores as plain text
        // with no conversion step in which an artefact could appear.
        richBody = message.richBody ?? RichBody(plainText: message.bodyText)
        attachments = message.attachments
        if let threadID = message.threadID, let accountID = message.accountID {
            activeContext = .reply(mode: .reply, thread: ComposeThreadReference(
                threadID: threadID, accountID: accountID,
                lastMessageRFC822ID: message.inReplyToMessageID))
        } else {
            activeContext = .new
            selectedFromAccountID = message.accountID
        }
    }

    func rfc5322(for address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    /// Empties the composer. Deliberately does NOT retire the keeper — the two
    /// callers that need that (`send`, and deleting the edited draft) do it
    /// explicitly, because `clear` is also how a session legitimately starts over
    /// and a retire there would be silent.
    func clear() {
        toChips = []; ccChips = []; bccChips = []; subject = ""; bodyText = ""
        attachments = []
        copyFieldsExpanded = false
        selectedFromAccountID = nil
        scheduledSendAt = nil
        isScheduling = false
        activeContext = .new
    }
    func undoSend() {
        guard let undoableEntryID else { return }
        if let message = runtime.outbox.cancelHeld(undoableEntryID) {
            // Restored exactly as `load` would show an existing draft: the
            // recipient chips, subject, and body come straight back into the
            // composer rather than being silently discarded.
            let restoredID = keeper.save(message, generation: keeper.generation)
            self.undoableEntryID = nil
            self.undoDeadline = nil
            if let restoredID {
                load(restoredID, message)
            }
            draftsVersion += 1
        }
    }
}
