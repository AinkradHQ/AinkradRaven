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

    @State var activeContext: ComposeContext
    @State var toChips: [RecipientChip] = []
    @State var ccChips: [RecipientChip] = []
    /// Blind carbon copies. Behind the `Cc & Bcc` disclosure with `ccChips` —
    /// see `ComposeRecipients` for why they are collapsed by default.
    @State var bccChips: [RecipientChip] = []
    /// Whether that disclosure is open. Opened automatically whenever the
    /// fields behind it are non-empty, so a collapsed section can never hide a
    /// recipient.
    @State var copyFieldsExpanded = false
    @State var subject = ""
    @State var bodyText = ""
    /// Files the user attached via `ComposeAttachmentPicker`, in pick order. Emitted as
    /// one MIME part per file — see `GmailProvider.rfc822`. Held in memory
    /// only, like every other attachment byte stream in this app.
    @State var attachments: [OutgoingAttachment] = []
    /// Owns the one `DraftBox` entry this composing session writes to, plus the
    /// generation guard that stops a debounced autosave landing after a send has
    /// removed the draft. See `ComposeDraftKeeper`.
    @State var keeper = ComposeDraftKeeper()
    @State private var isSending = false
    /// The `.confirm` findings a Send press stopped on, and the dialog showing
    /// them. Emptied on confirm or cancel — never remembered, so a user who
    /// fixes the problem and presses Send again is not shown the stale warning.
    @State private var pendingConfirmations: [ComposeFinding] = []
    @State private var isConfirmingSend = false
    /// "Saving…" / "Draft saved" under the footer. `nil` before the first
    /// autosave of a session.
    @State var draftStateText: String?
    /// Bumped after every draft mutation so the list re-reads `DraftBox`,
    /// which is a plain in-memory box rather than an `@Observable` type.
    @State var draftsVersion = 0
    /// The explicit sender for a NEW message, chosen from the picker below.
    /// This is local to Compose, not `model.accountID` (the Inbox filter) —
    /// picking a from-account for one message must not also re-scope the
    /// Inbox list. `nil` until the user picks one; with a single connected
    /// account there is nothing to pick, and `effectiveAccountID` resolves it
    /// silently via `runtime.composingAccountID` instead.
    @State var selectedFromAccountID: String?
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
    @State var didPrefill = false

    /// Send/queued/scheduled feedback. Replaces the `AinkradBanner` that used to
    /// sit between the body field and the footer: a banner there pushed the
    /// fields around while the user was reading it, and stayed until dismissed
    /// even after they had moved on. Toasts stack top-trailing over the
    /// composer, out of the form's way.
    ///
    /// The host is mounted in `RavenShell` around this view rather than on it —
    /// `.ainkradToastHost()` re-injects its own center for its CONTENT, so a
    /// view that mounts the host cannot read the center it renders from.
    @Environment(\.ainkradToastCenter) private var toasts

    /// Dwell time for a toast the user may need to ACT on — a failed queue, a
    /// refused route, an oversized attachment. The kit's 3s default is right for
    /// "Sent." and much too short to read a sentence explaining what to do next.
    static let alertToast: TimeInterval = 9

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
    /// account by `ComposeContext.stamp`, never to this picker. Internal, not
    /// private: `ComposeSurfaceAdvice` needs it to resolve the sending address.
    var effectiveAccountID: String? {
        selectedFromAccountID ?? runtime.composingAccountID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            ComposeTitleBar(context: activeContext, isEditingDraft: keeper.draftID != nil,
                           onClose: onClose)
            // Two columns, deliberately: the composer is the PRIMARY column and
            // takes all the width left over, the drafts rail is a fixed
            // secondary column pinned to the trailing edge. It used to be the
            // other way round — the rail first, at a fixed 220, with
            // `.frame(maxHeight: .infinity)` applied OUTSIDE its
            // `AinkradSectionFrame`, so the frame stretched but the card inside
            // it centred vertically. That is the screenshot exactly: fields
            // shoved right, dead space left, a chamfered DRAFTS card floating in
            // the middle of it, anchored to nothing.
            //
            // `.top` alignment keeps both columns starting at the same line, and
            // `showsRail` (not `showsDraftsRail`) is what decides whether the
            // second column exists at all.
            HStack(alignment: .top, spacing: AinkradSpacing.md) {
                composer
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if showsRail {
                    draftList
                        .frame(width: Self.draftsRailWidth)
                }
            }
        }
        .task { prefillIfNeeded() }
        // Publishes the draft as agent context on every edit, keyed on the same
        // digest the autosave debounces on — so "make this more formal" reaches
        // Sage as the text actually on screen. Nothing here calls a model; see
        // `ComposeDraftPublisher`.
        .onChange(of: autosaveKey, initial: true) { _, _ in
            ComposeDraftPublisher.shared.publish(stampedMessage())
        }
        // The composer is closed, so there is no open draft. Left set, Sage
        // would answer "shorten this" about a message the user walked away from.
        .onDisappear { ComposeDraftPublisher.shared.publish(nil) }
        // The autosave. `.task(id:)` is the debounce: SwiftUI cancels the
        // in-flight task and starts a new one every time `autosaveKey` changes,
        // so a burst of keystrokes performs exactly one write, `delay` after the
        // last of them. Nothing here depends on the view being torn down.
        .task(id: autosaveKey) { await autosave() }
        // Belt and braces only. The guarantee is the autosave above; this just
        // flushes a change made inside the debounce window when the overlay is
        // dismissed in that window.
        .onDisappear(perform: preserveDraft)
        // Scoped to the composer's own bounds, which is what makes this the
        // right control for the job: the guards are about THIS message, and a
        // window-level alert would dim the mail list the user may want to check
        // before answering.
        //
        // Confirm, never block. `ComposeFinding.Severity.confirm` is documented
        // for why: a client that refuses an empty-subject send is wrong about
        // the user's intent some of the time, and unappealable while wrong.
        .ainkradConfirmDialog(
            isPresented: $isConfirmingSend,
            title: "Before This Goes Out",
            message: pendingConfirmations.map(\.message).joined(separator: "\n\n"),
            confirmTitle: scheduledSendAt == nil ? "Send Anyway" : "Schedule Anyway",
            onConfirm: performSend)
    }
    // MARK: Drafts rail

    /// The width the rail earns when it is shown. Matches
    /// `RavenShell.draftsRailMinWidth`'s assumption about what a rail costs.
    private static let draftsRailWidth: CGFloat = 220

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
    private var showsRail: Bool { showsDraftsRail && savedDraftCount > 0 }

    /// Read through `draftsVersion` for the same reason `ComposeDraftsRail`
    /// does: `DraftBox` is a plain in-memory box, not observable.
    private var savedDraftCount: Int {
        _ = draftsVersion
        return DraftBox.shared.all().count
    }

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
        bccChips = message.bcc.map { RecipientChip(raw: rfc5322(for: $0)) }
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

    func rfc5322(for address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    /// Empties the composer. Deliberately does NOT retire the keeper — the two
    /// callers that need that (`send`, and deleting the edited draft) do it
    /// explicitly, because `clear` is also how a session legitimately starts over
    /// and a retire there would be silent.
    private func clear() {
        toChips = []; ccChips = []; bccChips = []; subject = ""; bodyText = ""
        attachments = []
        copyFieldsExpanded = false
        selectedFromAccountID = nil
        scheduledSendAt = nil
        isScheduling = false
        activeContext = .new
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            ComposeRecipients(runtime: runtime, context: activeContext,
                              toChips: $toChips, ccChips: $ccChips, bccChips: $bccChips,
                              selectedFromAccountID: $selectedFromAccountID,
                              isExpanded: $copyFieldsExpanded,
                              candidates: suggestionCandidates)
            AinkradTextField(text: $subject, placeholder: "Subject")
            AinkradTextArea(text: $bodyText, placeholder: "Write your message\u{2026}",
                            minHeight: 140)
                // **Base text direction, set — not implemented.**
                //
                // An Arabic message typed into an implicitly left-to-right
                // editor has its cursor, its alignment and its punctuation on
                // the wrong side, and the same message arrives laid out
                // left-to-right at the far end. Handing the direction to
                // SwiftUI's `layoutDirection` (and, in the sent message, to an
                // HTML `dir` attribute — see `GmailProvider.rfc822`) lets the
                // system's Unicode bidi algorithm do the reordering it already
                // does correctly. The only thing it cannot infer is the
                // paragraph's base direction, and that is the one thing set
                // here.
                //
                // Scoped to the editor alone, deliberately: mirroring the whole
                // composer would move the Send button and the drafts rail, which
                // are app chrome and belong wherever the host's own layout
                // direction puts them.
                .environment(\.layoutDirection,
                             BaseTextDirection.detect(bodyText) == .rightToLeft
                                ? .rightToLeft : .leftToRight)

            ComposeAdviceView(findings: findings, onApply: apply)

            ComposeAttachmentsRow(attachments: $attachments)

            // Shown for the length of the undo-send hold window right after
            // `send()` queues a message — see `undoableEntryID`. Pressing Undo
            // pulls the entry back out of the outbox via `Outbox.cancelHeld` and
            // restores it as an editable draft; letting the deadline pass just
            // lets the scheduled wake (or, failing that, the 120s backstop
            // timer) drain and transmit it — no special-casing needed here.
            if let undoDeadline {
                ComposeUndoBanner(deadline: undoDeadline, holdWindow: runtime.holdWindow,
                                 appearance: runtime.appearanceStore.appearance,
                                 onUndo: undoSend)
            }

            // Pushes the action row to the BOTTOM of the primary column instead
            // of letting it float directly under the body field with dead space
            // beneath it. `minLength: 0` so it collapses in a short window
            // rather than forcing the fields off the bottom.
            Spacer(minLength: 0)
            footer
        }
    }

    /// Attach, schedule, save and send on one row. Lives in
    /// `ComposeFooterBar` — extracted when the schedule presets arrived and
    /// this file was already near the 500-line cap.
    private var footer: some View {
        ComposeFooterBar(
            canSend: ComposeValidation.canSend(toChips),
            isSending: isSending,
            isScheduling: $isScheduling,
            scheduledSendAt: $scheduledSendAt,
            draftStateText: draftStateText,
            onAttach: { attachments.append(contentsOf: ComposeAttachmentPicker.pick()) },
            onSaveDraft: saveDraft,
            onSend: send)
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
    func message() -> OutgoingMessage {
        OutgoingMessage(
            to: ComposeValidation.validAddresses(toChips),
            cc: ComposeValidation.validAddresses(ccChips),
            bcc: ComposeValidation.validAddresses(bccChips),
            subject: subject,
            bodyText: bodyText,
            attachments: attachments)
    }

    /// The message plus its routing/threading stamps. One function, used by
    /// Save Draft, `preserveDraft` and `send`, so a saved draft and the message
    /// that eventually goes out cannot disagree about which mailbox owns them
    /// or which conversation they belong to.
    func stampedMessage() -> OutgoingMessage {
        activeContext.stamp(message(), fallbackAccountID: effectiveAccountID)
    }

    /// The explicit Save Draft button. The autosave already covers the same
    /// ground; this stays because "I pressed Save" deserves an immediate,
    /// visible result rather than a 600ms wait.
    private func saveDraft() {
        guard keeper.save(stampedMessage(), generation: keeper.generation) != nil else {
            toasts.show("Could not save draft.", status: .danger, duration: Self.alertToast)
            return
        }
        draftStateText = "Draft saved"
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
    /// The Send button. Runs the guards first and stops on anything that needs
    /// a human answer; `performSend` is the half that actually queues.
    ///
    /// The split matters: the confirm dialog's Confirm calls `performSend`
    /// DIRECTLY, so confirming cannot re-run the guards and stop again on the
    /// same finding, and cannot pick up a finding that appeared while the dialog
    /// was up.
    private func send() {
        guard ComposeValidation.canSend(toChips) else { return }
        let confirmations = ComposeAdvice.confirmations(findings)
        guard confirmations.isEmpty else {
            pendingConfirmations = confirmations
            isConfirmingSend = true
            return
        }
        performSend()
    }

    private func performSend() {
        pendingConfirmations = []
        guard ComposeValidation.canSend(toChips) else { return }
        let outgoing = stampedMessage()
        // Refuses rather than guessing which mailbox this goes out from — see
        // `effectiveAccountID`/`RavenRuntime.composingAccountID`. Nothing is
        // queued, so nothing can later leave from the wrong address. A reply is
        // always attributed (to the thread's account) and so never lands here.
        guard outgoing.accountID != nil else {
            toasts.show("Several accounts are connected, so Raven cannot tell which one should "
                        + "send this. Choose a From account above; nothing was queued.",
                        status: .warning, duration: Self.alertToast)
            return
        }
        isSending = true
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
                    toasts.show("Sent.", status: .success)
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
                    // Read BEFORE `clear()`, which resets `scheduledSendAt`.
                    let scheduleNote = scheduledFor.map {
                        "Scheduled for " + MailDateLabel.short(for: $0) + "."
                    }
                    clear()
                    draftStateText = nil
                    toasts.show(scheduleNote ?? "Queued — you can still undo it.",
                                status: .success)
                } else {
                    toasts.show(result.message, status: .danger, duration: Self.alertToast)
                }
                draftsVersion += 1
            } catch MailError.attachmentsTooLarge(let message) {
                // Refused before anything was queued (see `AttachmentSizeGuard`)
                // — the message itself already says what to do about it.
                toasts.show(message, status: .warning, duration: Self.alertToast)
            } catch {
                toasts.show("Could not queue send: \(error). Your message was not sent and has "
                            + "been left in the composer.",
                            status: .danger, duration: Self.alertToast)
            }
            isSending = false
        }
    }
}
