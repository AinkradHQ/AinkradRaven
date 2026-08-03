import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AinkradAppKit
import AinkradAppKitUI

/// The ONE composing surface, presented as an overlay by `RavenShell`.
///
/// New mail, Reply, Reply-all and Forward all arrive here, differing only by
/// the `ComposeContext` handed in — which carries the routing and threading
/// facts (see `ComposeContext.stamp`). Before this there were two composers:
/// this one for new mail and an inline panel on the thread pane for replies,
/// each with its own fields, its own validation and its own send call.
///
/// Drafts Sage (the MCP `create_draft` tool) creates land in `DraftBox.shared`,
/// the same in-memory box this view reads — so a draft created by an agent
/// conversation shows up here, and one typed here is what `send_draft` would
/// send.
///
/// **Dismissal never discards work.** The overlay can be closed by the scrim,
/// by Esc, or by the close button, none of which route through Send, so
/// `onDisappear` saves whatever is typed as a draft (see `preserveDraft`). The
/// "a draft is removed if and only if the message was sent" invariant is
/// unchanged: `send()` is still the only thing that removes one.
public struct ComposeSurface: View {
    let runtime: RavenRuntime
    /// How this composer was opened. `activeContext` below is what it is
    /// currently composing, which loading a saved draft can change.
    let context: ComposeContext
    /// Whether there is room for the drafts rail beside the fields. The shell
    /// decides this from the width it actually has — see
    /// `RavenShell.composeWidth(in:)`. When false the rail is dropped rather
    /// than squeezed; its drafts are still there, one reopen away.
    let showsDraftsRail: Bool
    let onClose: () -> Void

    @State private var activeContext: ComposeContext
    @State private var toChips: [RecipientChip] = []
    @State private var ccChips: [RecipientChip] = []
    @State private var subject = ""
    @State private var bodyText = ""
    /// Files the user attached via `ComposeAttachmentPicker`, in pick order. Emitted as
    /// one MIME part per file — see `GmailProvider.rfc822`. Held in memory
    /// only, like every other attachment byte stream in this app.
    @State private var attachments: [OutgoingAttachment] = []
    /// Owns the one `DraftBox` entry this composing session writes to, plus the
    /// generation guard that stops a debounced autosave landing after a send has
    /// removed the draft. See `ComposeDraftKeeper`.
    @State private var keeper = ComposeDraftKeeper()
    @State private var isSending = false
    @State private var errorMessage: String?
    /// Styling for `errorMessage`. A still-queued send is not a failure, and
    /// showing it in red invites the user to press Send again — which queues a
    /// SECOND message that will also go out. Warning styling matches what the
    /// text actually says.
    @State private var errorStatus: AinkradStatus = .danger
    /// Bumped after every draft mutation so the list re-reads `DraftBox`,
    /// which is a plain in-memory box rather than an `@Observable` type.
    @State private var draftsVersion = 0
    /// The explicit sender for a NEW message, chosen from the picker below.
    /// This is local to Compose, not `model.accountID` (the Inbox filter) —
    /// picking a from-account for one message must not also re-scope the
    /// Inbox list. `nil` until the user picks one; with a single connected
    /// account there is nothing to pick, and `effectiveAccountID` resolves it
    /// silently via `runtime.composingAccountID` instead.
    @State private var selectedFromAccountID: String?
    /// A future time picked in `schedulePicker`, or `nil` for "send normally
    /// (subject only to the undo-send hold window)". Reset on `clear()`.
    @State private var scheduledSendAt: Date?
    @State private var isScheduling = false
    /// The most recently queued send's outbox entry, while it is still inside
    /// its undo-send hold window — set right after `send()` queues it, and
    /// the target of the "Undo" button in `undoBanner`. `nil` once the hold
    /// elapses (the periodic timer transmits it) or the user cancels it.
    @State private var undoableEntryID: UUID?
    @State private var undoDeadline: Date?
    /// True once the reply/forward prefill has run, so re-rendering never
    /// overwrites what the user has since typed.
    @State private var didPrefill = false

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    public init(runtime: RavenRuntime, context: ComposeContext = .new,
                showsDraftsRail: Bool = true,
                onClose: @escaping () -> Void = {}) {
        self.runtime = runtime
        self.context = context
        self.showsDraftsRail = showsDraftsRail
        self.onClose = onClose
        _activeContext = State(initialValue: context)
    }

    /// The account a NEW message actually goes out from: the picker's choice
    /// if the user made one, otherwise whatever `RavenRuntime.
    /// composingAccountID` already resolves unambiguously (the sole account,
    /// or the Inbox's own filter). `nil` only when several accounts are
    /// connected, none is the Inbox filter, and the picker has not been used
    /// — exactly the case `send()` still refuses rather than guesses.
    ///
    /// Irrelevant to a reply, which is always attributed to the thread's own
    /// account by `ComposeContext.stamp`, never to this picker.
    private var effectiveAccountID: String? {
        selectedFromAccountID ?? runtime.composingAccountID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            ComposeTitleBar(context: activeContext, isEditingDraft: keeper.draftID != nil,
                           onClose: onClose)
            HStack(alignment: .top, spacing: AinkradSpacing.md) {
                if showsDraftsRail {
                    draftList
                        .frame(width: 220)
                }
                composer
                    .frame(maxWidth: .infinity)
            }
        }
        .task { prefillIfNeeded() }
        // The autosave. `.task(id:)` is the debounce: SwiftUI cancels the
        // in-flight task and starts a new one every time `autosaveKey` changes,
        // so a burst of keystrokes performs exactly one write, `delay` after the
        // last of them. Nothing here depends on the view being torn down.
        .task(id: autosaveKey) { await autosave() }
        // Belt and braces only. The guarantee is the autosave above; this just
        // flushes a change made inside the debounce window when the overlay is
        // dismissed in that window.
        .onDisappear(perform: preserveDraft)
    }

    /// Suggestion pool for both the To and Cc fields, rebuilt from whatever
    /// month shards the Inbox has already loaded (`RavenViewModel.summaries`).
    /// This never issues its own fetch — it only ranks what is already local.
    private var suggestionCandidates: [RecipientSuggestions.Candidate] {
        RecipientSuggestions.candidates(from: runtime.model.summaries)
    }

    // MARK: Prefill and draft preservation

    /// Fills the fields from `ReplyComposer` for a reply/forward. Runs once —
    /// `didPrefill` guards it — because the overlay's body re-runs on every
    /// keystroke and re-prefilling would erase what was typed.
    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true
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
    private static let autosaveDelay: Duration = .milliseconds(600)

    /// The digest `.task(id:)` watches. Every editable field is in it, so any
    /// change restarts the debounce, and nothing else is, so an unrelated
    /// re-render (a hover, a drafts-list refresh) does not schedule a write.
    ///
    /// Recipient chips contribute their raw text rather than their parsed
    /// address: a half-typed recipient is still an edit worth saving.
    private var autosaveKey: String {
        [toChips.map(\.raw).joined(separator: ","),
         ccChips.map(\.raw).joined(separator: ","),
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
    private func autosave() async {
        guard hasContent else { return }
        let generation = keeper.generation
        try? await Task.sleep(for: Self.autosaveDelay)
        guard !Task.isCancelled else { return }
        if keeper.save(stampedMessage(), generation: generation) != nil {
            // So the rail shows the draft appearing as it is typed.
            draftsVersion += 1
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
    private func preserveDraft() {
        guard hasContent else { return }
        keeper.save(stampedMessage(), generation: keeper.generation)
    }

    /// Whether there is anything worth keeping. Deliberately strict about
    /// emptiness so opening the composer and immediately closing it does not
    /// litter the drafts list with blanks.
    private var hasContent: Bool {
        !toChips.isEmpty || !ccChips.isEmpty || !attachments.isEmpty
            || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Drafts rail

    private var draftList: some View {
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
    private func load(_ id: String, _ message: OutgoingMessage) {
        // Autosaves from here on update THIS entry rather than forking a copy.
        keeper.adopt(id)
        toChips = message.to.map { RecipientChip(raw: rfc5322(for: $0)) }
        ccChips = message.cc.map { RecipientChip(raw: rfc5322(for: $0)) }
        subject = message.subject
        bodyText = message.bodyText
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

    private func rfc5322(for address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    /// Empties the composer. Deliberately does NOT retire the keeper — the two
    /// callers that need that (`send`, and deleting the edited draft) do it
    /// explicitly, because `clear` is also how a session legitimately starts over
    /// and a retire there would be silent.
    private func clear() {
        toChips = []; ccChips = []; subject = ""; bodyText = ""
        attachments = []
        selectedFromAccountID = nil
        scheduledSendAt = nil
        isScheduling = false
        activeContext = .new
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            // Only a NEW message has a From to choose. A reply's account is the
            // thread's, with no override — offering a picker that `stamp` would
            // then ignore is worse than offering none.
            if activeContext.thread == nil, runtime.accounts.count > 1 {
                ComposeFromPicker(runtime: runtime, selection: $selectedFromAccountID)
            } else if let thread = activeContext.thread,
                      let address = runtime.ownAddress(for: thread.accountID) {
                ComposeFieldWrap(label: "From") {
                    Text(address)
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                        .foregroundStyle(theme.foreground.opacity(0.7))
                }
            }
            RecipientChipField(label: "To", chips: $toChips, candidates: suggestionCandidates)
            RecipientChipField(label: "Cc", chips: $ccChips, candidates: suggestionCandidates)
            AinkradTextField(text: $subject, placeholder: "Subject")
            AinkradTextArea(text: $bodyText, placeholder: "Write your message…", minHeight: 140)

            ComposeAttachmentsRow(attachments: $attachments)

            if let errorMessage {
                AinkradBanner(message: errorMessage, status: errorStatus,
                              onDismiss: { self.errorMessage = nil })
            }

            // Shown for the length of the undo-send hold window right after
            // `send()` queues a message — see `undoableEntryID`. Pressing Undo
            // pulls the entry back out of the outbox via `Outbox.cancelHeld` and
            // restores it as an editable draft; letting the deadline pass just
            // lets the scheduled wake (or, failing that, the 120s backstop
            // timer) drain and transmit it — no special-casing needed here.
            if let undoDeadline {
                ComposeUndoBanner(deadline: undoDeadline, holdWindow: runtime.holdWindow,
                                 onUndo: undoSend)
            }

            footer
        }
    }

    /// Attach, schedule, save and send on one row. These used to be three
    /// separate stacked rows of full-width buttons, which made the composer
    /// taller than the message being written.
    private var footer: some View {
        HStack(spacing: AinkradSpacing.xs) {
            AinkradIconButton(systemName: "paperclip", size: 26, tooltip: "Attach files…") {
                attachments.append(contentsOf: ComposeAttachmentPicker.pick())
            }
            AinkradIconButton(systemName: "clock", size: 26,
                              tooltip: isScheduling ? "Cancel scheduling" : "Schedule for later") {
                isScheduling.toggle()
                if !isScheduling { scheduledSendAt = nil }
            }
            if isScheduling { schedulePicker }
            Spacer(minLength: AinkradSpacing.xs)
            AinkradButton(title: "Save Draft", style: .ghost, action: saveDraft)
            AinkradButton(title: scheduledSendAt == nil ? "Send" : "Schedule Send",
                          style: .primary, icon: "paperplane",
                          isLoading: isSending, action: send)
                .disabled(!ComposeValidation.canSend(toChips) || isSending)
        }
    }

    /// Scheduled send: a simple future-time affordance, deliberately not
    /// over-built. Made plain in the UI (not just a code comment) that this
    /// only fires while the app is running — a message scheduled for 3am
    /// while the Mac is asleep sends when the app next wakes, not at 3am.
    private var schedulePicker: some View {
        HStack(spacing: AinkradSpacing.xs) {
            DatePicker("", selection: Binding(
                get: { scheduledSendAt ?? Date().addingTimeInterval(3600) },
                set: { scheduledSendAt = $0 }),
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            AinkradIconGlyph(systemName: "info.circle")
                .ainkradTooltip("Raven must be running at the scheduled time for this to send — "
                                + "a message scheduled while your Mac is asleep sends when the "
                                + "app next wakes, not exactly at the time you picked.")
        }
    }

    private func undoSend() {
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

    /// The typed content as an `OutgoingMessage`, before routing.
    private func message() -> OutgoingMessage {
        OutgoingMessage(
            to: ComposeValidation.validAddresses(toChips),
            cc: ComposeValidation.validAddresses(ccChips),
            subject: subject,
            bodyText: bodyText,
            attachments: attachments)
    }

    /// The message plus its routing/threading stamps. One function, used by
    /// Save Draft, `preserveDraft` and `send`, so a saved draft and the message
    /// that eventually goes out cannot disagree about which mailbox owns them
    /// or which conversation they belong to.
    private func stampedMessage() -> OutgoingMessage {
        activeContext.stamp(message(), fallbackAccountID: effectiveAccountID)
    }

    /// The explicit Save Draft button. The autosave already covers the same
    /// ground; this stays because "I pressed Save" deserves an immediate,
    /// visible result rather than a 600ms wait.
    private func saveDraft() {
        guard keeper.save(stampedMessage(), generation: keeper.generation) != nil else {
            errorMessage = "Could not save draft."
            errorStatus = .danger
            return
        }
        draftsVersion += 1
    }

    /// Clears the composer and deletes the draft ONLY when the send genuinely
    /// went out. Every other outcome — queued, dead-lettered, held for review,
    /// or a failure to even queue — keeps the typed text (recipient chips,
    /// subject, body) and the draft, and says what happened. `SendAttempt` is
    /// the same function the MCP `send_draft` tool calls, so the human path
    /// and the agent path cannot drift apart on the one operation that can't
    /// be undone.
    ///
    /// Replies go through this same call rather than
    /// `RavenRuntime.sendThreadReply`, which is `SendAttempt.send` with
    /// `draftID: nil` and no `sendAt` — a strict subset. Routing them here
    /// means a reply gets the undo window and scheduling the composer is
    /// showing, instead of a schedule picker that would be silently ignored.
    private func send() {
        guard ComposeValidation.canSend(toChips) else { return }
        let outgoing = stampedMessage()
        // Refuses rather than guessing which mailbox this goes out from — see
        // `effectiveAccountID`/`RavenRuntime.composingAccountID`. Nothing is
        // queued, so nothing can later leave from the wrong address. A reply is
        // always attributed (to the thread's account) and so never lands here.
        guard outgoing.accountID != nil else {
            errorMessage = "Several accounts are connected, so Raven cannot tell which one " +
                           "should send this. Choose a From account above; nothing was queued."
            errorStatus = .warning
            return
        }
        isSending = true
        errorMessage = nil
        let draftID = keeper.draftID
        let holdUntil = Date().addingTimeInterval(runtime.holdWindow)
        let scheduledFor = scheduledSendAt
        Task {
            do {
                let result = try await SendAttempt.send(outgoing, draftID: draftID,
                                                        outbox: runtime.outbox,
                                                        store: runtime.store,
                                                        holdUntil: holdUntil,
                                                        sendAt: scheduledFor,
                                                        drain: runtime.drainOutbox)
                if result.isSent {
                    // Transmitted immediately in this same call — only
                    // possible if a test or future caller passes a `nil`
                    // hold; the two real send paths always pass one.
                    // `SendAttempt` removed the draft on `.sent`; retiring here
                    // is what stops an autosave scheduled before this send from
                    // writing it back afterwards. Retired ONLY on the two
                    // outcomes that actually remove the draft — retiring on a
                    // failure would detach from the surviving entry and let the
                    // next autosave create a duplicate of it.
                    keeper.retire()
                    clear()
                } else if result.outcome.isBenign {
                    // Held (undo window) and/or scheduled: the message left
                    // the composer, exactly like a genuine send, but stays
                    // cancelable via `undoBanner` until `holdUntil` elapses.
                    // Its content is not lost — it lives on the outbox entry
                    // (`OutboxEntry.draftID`/the entry itself) and `undoSend`
                    // can pull it back via `Outbox.cancelHeld`.
                    if let draftID { DraftBox.shared.remove(draftID) }
                    keeper.retire()
                    undoableEntryID = result.entryID
                    undoDeadline = holdUntil
                    clear()
                } else {
                    errorMessage = result.message
                    errorStatus = .danger
                }
                draftsVersion += 1
            } catch MailError.attachmentsTooLarge(let message) {
                // Refused before anything was queued (see `AttachmentSizeGuard`)
                // — the message itself already says what to do about it.
                errorMessage = message
                errorStatus = .warning
            } catch {
                errorMessage = "Could not queue send: \(error). Your message was not sent " +
                               "and has been left in the composer."
                errorStatus = .danger
            }
            isSending = false
        }
    }
}
