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

    public init(runtime: RavenRuntime) { self.runtime = runtime }

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
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            RecipientChipField(label: "To", chips: $toChips, candidates: suggestionCandidates)
            RecipientChipField(label: "Cc", chips: $ccChips, candidates: suggestionCandidates)
            AinkradTextField(text: $subject, placeholder: "Subject")
            AinkradTextArea(text: $bodyText, placeholder: "Write your message…",
                            minHeight: 200)

            if let errorMessage {
                AinkradBanner(message: errorMessage, status: errorStatus,
                              onDismiss: { self.errorMessage = nil })
            }

            HStack {
                AinkradButton(title: "Save Draft", style: .secondary, action: saveDraft)
                Spacer()
                AinkradButton(title: "Send", style: .primary, icon: "paperplane",
                              isLoading: isSending, action: send)
                    .disabled(!ComposeValidation.canSend(toChips) || isSending)
            }
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
            accountID: runtime.composingAccountID)
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
        // `RavenRuntime.composingAccountID`. Nothing is queued, so nothing can
        // later leave from the wrong address.
        guard runtime.composingAccountID != nil else {
            errorMessage = "Several accounts are connected, so Raven cannot tell which one " +
                           "should send this. Filter the Inbox to one account first; nothing " +
                           "was queued."
            errorStatus = .warning
            return
        }
        isSending = true
        errorMessage = nil
        let outgoing = message()
        let draftID = editingDraftID
        Task {
            do {
                let result = try await SendAttempt.send(outgoing, draftID: draftID,
                                                        outbox: runtime.outbox,
                                                        store: runtime.store,
                                                        drain: runtime.drainOutbox)
                if result.isSent {
                    clear()
                } else {
                    errorMessage = result.message
                    errorStatus = result.outcome.isBenign ? .warning : .danger
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
