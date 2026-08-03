import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Compose plus the draft list. Drafts Sage (the MCP `create_draft` tool)
/// creates land in `DraftBox.shared`, the same in-memory box this view reads
/// — so a draft created by an agent conversation shows up here, and one
/// typed here is what `send_draft` would send.
public struct ComposeSurface: View {
    let runtime: RavenRuntime

    @State private var toChips: [RecipientChip] = []
    @State private var ccChips: [RecipientChip] = []
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var editingDraftID: String?
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

    public init(runtime: RavenRuntime) { self.runtime = runtime }

    /// The account a NEW message actually goes out from: the picker's choice
    /// if the user made one, otherwise whatever `RavenRuntime.
    /// composingAccountID` already resolves unambiguously (the sole account,
    /// or the Inbox's own filter). `nil` only when several accounts are
    /// connected, none is the Inbox filter, and the picker has not been used
    /// — exactly the case `send()` still refuses rather than guesses.
    private var effectiveAccountID: String? {
        selectedFromAccountID ?? runtime.composingAccountID
    }

    public var body: some View {
        HStack(alignment: .top, spacing: AinkradSpacing.md) {
            sidebar
                .frame(width: 260)
            composer
                .frame(maxWidth: .infinity)
        }
        .padding(AinkradSpacing.md)
        .ainkradPanel()
    }

    /// Suggestion pool for both the To and Cc fields, rebuilt from whatever
    /// month shards the Inbox has already loaded (`RavenViewModel.summaries`).
    /// This never issues its own fetch — it only ranks what is already local.
    private var suggestionCandidates: [RecipientSuggestions.Candidate] {
        RecipientSuggestions.candidates(from: runtime.model.summaries)
    }

    // MARK: Sidebar (drafts + needs-review)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            draftList
            needsReviewList
        }
    }

    private var draftList: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSectionHeader(title: "Drafts")
            let drafts = { _ = draftsVersion; return DraftBox.shared.all() }()
            if drafts.isEmpty {
                AinkradEmptyState(icon: "square.and.pencil", title: "No drafts",
                                  message: "Start a new message, or ask Sage to draft one.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(drafts, id: \.id) { entry in
                            AinkradListRow(
                                isSelected: editingDraftID == entry.id,
                                onTap: { load(entry.id, entry.message) },
                                leading: { AinkradIconGlyph(systemName: "square.and.pencil") },
                                title: entry.message.subject.isEmpty ? "(no subject)" : entry.message.subject,
                                subtitle: entry.message.to.first?.displayLabel,
                                trailing: {
                                    AinkradIconButton(systemName: "trash", tooltip: "Delete draft") {
                                        DraftBox.shared.remove(entry.id)
                                        if editingDraftID == entry.id { clear() }
                                        draftsVersion += 1
                                    }
                                })
                        }
                    }
                }
            }
        }
    }

    /// Sends that were in flight when a previous process died — `Outbox`
    /// pulls these out of `pending()` on load rather than guess whether they
    /// actually transmitted (see `Outbox`'s own documentation), so a human
    /// must resolve each one here: discard it (nothing is known to have been
    /// sent, so discarding just drops the queued copy) or leave it for now.
    private var needsReviewList: some View {
        let entries = runtime.outbox.needsReview()
        return Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                    AinkradSectionHeader(title: "Needs review",
                                        subtitle: "A previous session quit mid-send; confirm before resending.")
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(entries, id: \.id) { entry in
                                AinkradListRow(
                                    onTap: nil,
                                    leading: { AinkradIconGlyph(systemName: "exclamationmark.triangle") },
                                    title: entryTitle(entry),
                                    subtitle: "Outcome unknown — check before resending.",
                                    trailing: {
                                        AinkradIconButton(systemName: "trash", tooltip: "Discard (nothing confirmed sent)") {
                                            try? runtime.outbox.discard(entry.id)
                                            draftsVersion += 1
                                        }
                                    })
                            }
                        }
                    }
                }
            }
        }
    }

    private func entryTitle(_ entry: OutboxEntry) -> String {
        switch entry.operation {
        case .send(let message): return message.subject.isEmpty ? "(no subject)" : message.subject
        case .labels: return "Label change"
        }
    }

    private func load(_ id: String, _ message: OutgoingMessage) {
        editingDraftID = id
        toChips = message.to.map { RecipientChip(raw: rfc5322(for: $0)) }
        ccChips = message.cc.map { RecipientChip(raw: rfc5322(for: $0)) }
        subject = message.subject
        bodyText = message.bodyText
    }

    private func rfc5322(for address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    private func clear() {
        editingDraftID = nil
        toChips = []; ccChips = []; subject = ""; bodyText = ""
        selectedFromAccountID = nil
        scheduledSendAt = nil
        isScheduling = false
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            if runtime.accounts.count > 1 {
                fromAccountPicker
            }
            RecipientChipField(label: "To", chips: $toChips, candidates: suggestionCandidates)
            RecipientChipField(label: "Cc", chips: $ccChips, candidates: suggestionCandidates)
            AinkradTextField(text: $subject, placeholder: "Subject")
            AinkradTextArea(text: $bodyText, placeholder: "Write your message…",
                            minHeight: 200)

            if let errorMessage {
                AinkradBanner(message: errorMessage, status: errorStatus,
                              onDismiss: { self.errorMessage = nil })
            }

            if let undoDeadline {
                undoBanner(deadline: undoDeadline)
            }

            schedulePicker

            HStack {
                AinkradButton(title: "Save Draft", style: .secondary, action: saveDraft)
                Spacer()
                AinkradButton(title: scheduledSendAt == nil ? "Send" : "Schedule Send",
                              style: .primary, icon: "paperplane",
                              isLoading: isSending, action: send)
                    .disabled(!ComposeValidation.canSend(toChips) || isSending)
            }
        }
    }

    /// Shown for the length of the undo-send hold window right after `send()`
    /// queues a message — see `undoableEntryID`. Pressing Undo pulls the
    /// entry back out of the outbox via `Outbox.cancelHeld` and restores it
    /// as an editable draft; letting the deadline pass just lets the
    /// scheduled wake (or, failing that, the 120s backstop timer) drain and
    /// transmit it — no special-casing needed here.
    ///
    /// Live, not static: a `TimelineView` redraws this once a second so the
    /// remaining time actually counts down instead of being frozen at
    /// whatever it read when the banner first appeared — the defect this
    /// view exists to fix (a user watching "Undo (20s)" with no way to tell
    /// whether it is running at all).
    ///
    /// `AinkradAppKitUI` was checked for an existing countdown/progress
    /// affordance first (see `AinkradMeter`, a determinate radial gauge
    /// driven by `value`/`total`) — it exists and fits exactly, so this
    /// reuses it rather than building a bespoke ring or bar. Only the
    /// second-by-second re-render (via `TimelineView`) and the remaining-
    /// seconds label next to it are specific to Compose.
    private func undoBanner(deadline: Date) -> some View {
        let started = runtime.holdWindow
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            HStack(spacing: AinkradSpacing.sm) {
                AinkradMeter(value: remaining, total: max(started, 1),
                            label: "undo", size: 36)
                Text("Sending in \(Int(remaining.rounded(.up)))s…")
                    .font(.caption).foregroundStyle(.secondary)
                AinkradButton(title: "Undo", style: .secondary, action: undoSend)
            }
        }
    }

    /// Scheduled send: a simple future-time affordance, deliberately not
    /// over-built. Made plain in the UI (not just a code comment) that this
    /// only fires while the app is running — a message scheduled for 3am
    /// while the Mac is asleep sends when the app next wakes, not at 3am.
    private var schedulePicker: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack {
                AinkradButton(title: isScheduling ? "Cancel Scheduling" : "Schedule for later",
                              style: .ghost, icon: "clock") {
                    isScheduling.toggle()
                    if !isScheduling { scheduledSendAt = nil }
                }
                if isScheduling {
                    DatePicker("", selection: Binding(
                        get: { scheduledSendAt ?? Date().addingTimeInterval(3600) },
                        set: { scheduledSendAt = $0 }),
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            if isScheduling {
                Text("Raven must be running at the scheduled time for this to send — a " +
                     "message scheduled while your Mac is asleep sends when the app next " +
                     "wakes, not exactly at the time you picked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func undoSend() {
        guard let undoableEntryID else { return }
        if let message = runtime.outbox.cancelHeld(undoableEntryID) {
            // Restored exactly as `load` would show an existing draft: the
            // recipient chips, subject, and body come straight back into the
            // composer rather than being silently discarded.
            let restoredID = try? DraftBox.shared.save(message, id: editingDraftID)
            self.undoableEntryID = nil
            self.undoDeadline = nil
            if let restoredID {
                load(restoredID, message)
            }
            draftsVersion += 1
        }
    }

    /// Only for a NEW message — never shown for a reply/forward, which is
    /// composed on `ThreadSurface`/`ReplyComposer` and never routes through
    /// this view at all (its account comes from the thread being replied to,
    /// via `RavenRuntime.ownAddress`/`sendThreadReply`, with no override).
    /// `nil` renders as "Choose account" so an ambiguous send is visibly
    /// unresolved rather than looking like a default was silently picked.
    private var fromAccountPicker: some View {
        AinkradFieldWrap(label: "From") {
            AinkradSegmentedPicker(
                items: [nil] + runtime.accounts.map { Optional($0.id) },
                selection: $selectedFromAccountID,
                label: { accountID in
                    guard let accountID else {
                        // The "no explicit pick" segment. If something already
                        // resolves unambiguously (the Inbox's own filter), say
                        // which — otherwise this is genuinely unresolved, and
                        // `send()` refuses until a real segment is picked.
                        if let resolved = runtime.composingAccountID {
                            let address = runtime.accounts.first { $0.id == resolved }?.address
                            return address ?? resolved
                        }
                        return "Choose account"
                    }
                    return runtime.accounts.first { $0.id == accountID }?.address ?? accountID
                })
        }
    }

    /// Attributed to the composing account (`RavenRuntime.composingAccountID`)
    /// so the outbox transmits it through that mailbox's provider and
    /// `SendAttempt` appends that account's signature.
    private func message() -> OutgoingMessage {
        OutgoingMessage(
            to: ComposeValidation.validAddresses(toChips),
            cc: ComposeValidation.validAddresses(ccChips),
            subject: subject,
            bodyText: bodyText,
            accountID: effectiveAccountID)
    }

    private func saveDraft() {
        do {
            let id = try DraftBox.shared.save(message(), id: editingDraftID)
            editingDraftID = id
            draftsVersion += 1
        } catch {
            errorMessage = "Could not save draft: \(error)"
            errorStatus = .danger
        }
    }

    /// Clears the composer and deletes the draft ONLY when the send genuinely
    /// went out. Every other outcome — queued, dead-lettered, held for review,
    /// or a failure to even queue — keeps the typed text (recipient chips,
    /// subject, body) and the draft, and says what happened. `SendAttempt` is
    /// the same function the MCP `send_draft` tool calls, so the human path
    /// and the agent path cannot drift apart on the one operation that can't
    /// be undone.
    private func send() {
        guard ComposeValidation.canSend(toChips) else { return }
        // Refuses rather than guessing which mailbox this goes out from — see
        // `effectiveAccountID`/`RavenRuntime.composingAccountID`. Nothing is
        // queued, so nothing can later leave from the wrong address.
        guard effectiveAccountID != nil else {
            errorMessage = "Several accounts are connected, so Raven cannot tell which one " +
                           "should send this. Choose a From account above; nothing was queued."
            errorStatus = .warning
            return
        }
        isSending = true
        errorMessage = nil
        let outgoing = message()
        let draftID = editingDraftID
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
                    clear()
                } else if result.outcome.isBenign {
                    // Held (undo window) and/or scheduled: the message left
                    // the composer, exactly like a genuine send, but stays
                    // cancelable via `undoBanner` until `holdUntil` elapses.
                    // Its content is not lost — it lives on the outbox entry
                    // (`OutboxEntry.draftID`/the entry itself) and `undoSend`
                    // can pull it back via `Outbox.cancelHeld`.
                    if let draftID { DraftBox.shared.remove(draftID) }
                    undoableEntryID = result.entryID
                    undoDeadline = holdUntil
                    clear()
                } else {
                    errorMessage = result.message
                    errorStatus = .danger
                }
                draftsVersion += 1
            } catch {
                errorMessage = "Could not queue send: \(error). Your message was not sent " +
                               "and has been left in the composer."
                errorStatus = .danger
            }
            isSending = false
        }
    }
}

/// To/Cc chip field: typed text commits into a `RecipientChip` on return,
/// comma, or tab; backspace on an empty text field pops the last chip;
/// each chip carries its own remove control. A small suggestion list, ranked
/// by `RecipientSuggestions`, appears under the field while typing.
private struct RecipientChipField: View {
    let label: String
    @Binding var chips: [RecipientChip]
    let candidates: [RecipientSuggestions.Candidate]

    @State private var typed = ""
    @FocusState private var isFocused: Bool

    private var suggestions: [RecipientSuggestions.Candidate] {
        guard isFocused, !typed.isEmpty else { return [] }
        let alreadyChipped = Set(chips.compactMap { $0.address?.email.lowercased() })
        return RecipientSuggestions.match(typed, in: candidates)
            .filter { !alreadyChipped.contains($0.address.email.lowercased()) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            AinkradFieldWrap(label: label) {
                WrappingChips {
                    ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                        AinkradChip(label: chip.displayLabel,
                                   systemName: chip.isValid ? nil : "exclamationmark.triangle",
                                   onRemove: { chips.remove(at: index) })
                    }
                    TextField("", text: $typed)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .frame(minWidth: 80)
                        .onSubmit { commit() }
                        .onChange(of: typed) { _, newValue in
                            if newValue.hasSuffix(",") {
                                typed = String(newValue.dropLast())
                                commit()
                            }
                        }
                        .onKeyPress(.tab) {
                            guard !typed.isEmpty else { return .ignored }
                            commit()
                            return .handled
                        }
                        .onKeyPress(.delete) {
                            guard typed.isEmpty, !chips.isEmpty else { return .ignored }
                            chips.removeLast()
                            return .handled
                        }
                }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions.indices, id: \.self) { index in
                        let candidate = suggestions[index]
                        Button {
                            chips.append(RecipientChip(raw: rfc5322(for: candidate.address)))
                            typed = ""
                        } label: {
                            Text(candidate.address.name.map { "\($0) <\(candidate.address.email)>" }
                                ?? candidate.address.email)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, AinkradSpacing.sm)
                                .padding(.vertical, AinkradSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .ainkradPanel()
            }
        }
    }

    private func rfc5322(for address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    private func commit() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chips.append(RecipientChip(raw: text))
        typed = ""
    }
}

/// Minimal label + content wrapper matching the visual weight of
/// `AinkradTextField` without requiring a second, chip-aware component in
/// AinkradAppKitUI — Compose is the only caller that needs a labeled chip
/// field today.
private struct AinkradFieldWrap<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: AinkradSpacing.sm) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            content()
                .padding(.horizontal, AinkradSpacing.sm)
                .padding(.vertical, AinkradSpacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChamferShape(cut: 6).fill(Color.gray.opacity(0.08)))
    }
}

/// A simple left-to-right wrap layout for chips + the trailing text field.
private struct WrappingChips: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + AinkradSpacing.xs; rowHeight = 0
            }
            x += size.width + AinkradSpacing.xs
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + AinkradSpacing.xs; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + AinkradSpacing.xs
            rowHeight = max(rowHeight, size.height)
        }
    }
}
