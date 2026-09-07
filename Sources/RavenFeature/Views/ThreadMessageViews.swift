import SwiftUI
import AppKit
import Quartz
import AinkradAppKit
import AinkradAppKitUI

/// One message: sender line, the visible (non-quoted) body, a disclosure for
/// the quoted trailer `QuoteTrimmer` split off, attachment chips, and "Show
/// original".
struct MessageRow: View {
    let message: MailMessage
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    @State private var loadedBody: MessageBody?
    @State private var isLoading = false
    @State private var quotedExpanded = false
    @State private var showingOriginal = false

    /// The live surface setting. Read through the runtime's observable store so
    /// dragging the transparency slider in Settings repaints these cards
    /// immediately rather than at the next unrelated invalidation.
    private var appearance: RavenAppearance { runtime.appearanceStore.appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradIconGlyph(systemName: message.isRead ? "envelope.open" : "envelope.badge",
                                 filled: !message.isRead)
                Text(message.from?.displayLabel ?? "Unknown sender")
                    .font(AinkradFontResolver.font(.body, weight: .medium, typography: typo))
                    .foregroundStyle(theme.foreground)
                Spacer(minLength: AinkradSpacing.sm)
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.55))
            }

            content

            if let icsText = loadedBody?.icsText, let invite = ICalendar.parseFirstEvent(icsText) {
                CalendarInviteCard(invite: invite, threadID: message.threadID, runtime: runtime)
            }

            // Any agent-recorded label reason for this thread. Shown once per
            // thread — on its newest message — rather than repeated on every
            // card, since the record is about the thread's labels, not this
            // message's text.
            if isNewestInThread {
                LabelReasonNote(threadID: message.threadID, runtime: runtime)
            }

            if !message.attachments.isEmpty {
                AttachmentChipRow(attachments: message.attachments, messageID: message.id,
                                  threadID: message.threadID, runtime: runtime)
            }
        }
        .padding(AinkradSpacing.md)
        // Theme surface, not `Color.primary` — the host is themeable and a
        // primary-derived wash reads as grey on a tinted theme.
        //
        // The fill is DERIVED from the pane's, not chosen beside it: it is
        // exactly the layer needed for pane+card to composite to the user's
        // opacity plus a small elevation lift — see
        // `RavenAppearance.cardFillOpacity`. Two independently-picked
        // translucent fills is what made this card an opaque slab over an
        // already-glass pane (0.72 pane + 0.45·0.72 card ≈ 0.85 effective).
        .background(ChamferShape(cut: AinkradRadius.sm)
            .fill(theme.surfaceElevated.opacity(appearance.cardFillOpacity(isRead: message.isRead))))
        // What actually separates the card from its pane now that its fill is
        // a few percent: the chamfer plus a theme accent border, the same
        // language `AinkradCard` uses. Elevation without a second dark layer.
        .overlay(ChamferShape(cut: AinkradRadius.sm)
            .strokeBorder(theme.accentSecondary
                .opacity(appearance.cardBorderOpacity(isRead: message.isRead)),
                          lineWidth: message.isRead ? 1 : 1.5))
        .overlay(alignment: .leading) {
            // Unread messages carry an accent edge rather than a colour swap,
            // matching `AinkradListRow`'s own selected treatment.
            Rectangle()
                .fill(theme.accentSecondary)
                .frame(width: message.isRead ? 0 : 2)
        }
        .clipShape(ChamferShape(cut: AinkradRadius.sm))
        .task(id: message.id) {
            guard loadedBody == nil else { return }
            isLoading = true
            loadedBody = await runtime.loadBody(for: message)
            isLoading = false
        }
        // The kit's own scoped modal rather than a native `.sheet`: a system
        // sheet brings unthemed macOS chrome into a HUD surface, which is
        // exactly the inconsistency this overhaul is about.
        .ainkradModal(isPresented: $showingOriginal, contentWidth: 640) {
            if let html = loadedBody?.html {
                RawHTMLSheet(html: html, sender: message.from?.email, runtime: runtime,
                            onClose: { showingOriginal = false })
            }
        }
    }

    private var isNewestInThread: Bool {
        runtime.store.thread(message.threadID)?.messages.last?.id == message.id
    }

    @ViewBuilder private var content: some View {
        if isLoading && loadedBody == nil {
            AinkradLoadingState(label: "Loading message…")
        } else if let body = loadedBody {
            let split = QuoteTrimmer.split(body.plainText)
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                // Body text is the thing transparency most easily ruins, so
                // both its opacity and its halo come from `appearance` rather
                // than the old fixed 0.9/0.55 — see `RavenAppearance.
                // bodyTextOpacity`. At full opacity these evaluate to exactly
                // the previous numbers and the halo to nothing, so an opaque
                // Raven looks unchanged.
                Text(split.visible)
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(appearance.bodyTextOpacity))
                    .textSelection(.enabled)
                    .ravenLegibleText(appearance)

                if let quoted = split.quoted {
                    AinkradDisclosureGroup(title: "Show quoted text", isExpanded: $quotedExpanded) {
                        Text(quoted)
                            .font(AinkradFontResolver.font(.body, typography: typo))
                            .foregroundStyle(theme.foreground
                                .opacity(appearance.secondaryTextOpacity))
                            .textSelection(.enabled)
                            .ravenLegibleText(appearance)
                    }
                }

                if body.html != nil {
                    // Kept per message as well as in the thread toolbar: the
                    // toolbar's copy acts on the NEWEST message with HTML, and
                    // an older message in a long thread still needs its own way
                    // to be seen as it was sent.
                    AinkradButton(title: "Show original", style: .ghost, icon: "safari") {
                        showingOriginal = true
                    }
                }
            }
        } else {
            Text("(body not synced)")
                .font(AinkradFontResolver.font(.body, typography: typo))
                .foregroundStyle(theme.foreground.opacity(0.55))
        }
    }
}

/// The most recent agent-recorded label reason for a thread (`label_with_reason`),
/// as a chip whose tooltip is the reason text in full.
///
/// Read straight from the store rather than passed in, because the record is
/// written by a tool call that never goes through `RavenViewModel` — a cached
/// copy would show a stale "why" (or none) after Sage filed the thread.
/// Renders nothing at all when there is no record, which is the ordinary case
/// for mail the user filed themselves.
struct LabelReasonNote: View {
    let threadID: String
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    private var latest: LabelReason? {
        guard let accountID = runtime.store.thread(threadID)?.accountID else { return nil }
        return runtime.store.labelReasons(accountID: accountID, threadID: threadID).first
    }

    var body: some View {
        if let latest {
            HStack(spacing: AinkradSpacing.xs) {
                AinkradIconGlyph(systemName: "text.badge.checkmark")
                Text(summary(latest))
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.7))
                    .lineLimit(2)
            }
            // The full text on hover: the chip line is truncated to two lines
            // so a 500-character reason cannot push the message body off
            // screen, and the untruncated record has to stay reachable.
            .help(latest.reason)
        }
    }

    /// "Labelled A, unlabelled B — <reason>", with whichever half applies. The
    /// labels are named because a reason without them records that something
    /// was justified but not what.
    private func summary(_ reason: LabelReason) -> String {
        var parts: [String] = []
        if !reason.add.isEmpty { parts.append("labelled \(reason.add.joined(separator: ", "))") }
        if !reason.remove.isEmpty {
            parts.append("unlabelled \(reason.remove.joined(separator: ", "))")
        }
        let what = parts.isEmpty ? "Labels reviewed" : parts.joined(separator: ", ").capitalizedFirst
        return "\(what) — \(reason.reason)"
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Attachment metadata as `AinkradChip`s. Tapping one fetches the bytes on
/// demand (in-memory only — never written to a cache directory) and hands
/// them to an `NSSavePanel`. See the task report for this fetch path's exact
/// wiring status.
struct AttachmentChipRow: View {
    let attachments: [MailAttachment]
    let messageID: String
    /// Needed to resolve which account's provider fetches the bytes — the
    /// message alone does not say which mailbox it lives in.
    let threadID: String
    let runtime: RavenRuntime

    @State private var downloadingID: String?
    @State private var errorMessage: String?

    /// Kept alive for the duration of an open QuickLook panel so its temp
    /// file is cleaned up (`AttachmentPreviewFile.cleanUp`) exactly once, when
    /// the panel closes — not left in the temp directory indefinitely, and
    /// not deleted out from under the panel while it is still showing it.
    @State private var activePreview: QuickLookAttachmentPreviewer?

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack(spacing: AinkradSpacing.xs) {
                ForEach(attachments, id: \.attachmentID) { attachment in
                    AinkradChip(label: chipLabel(attachment), systemName: "paperclip")
                        .opacity(downloadingID == attachment.attachmentID ? 0.5 : 1)
                        .onTapGesture { preview(attachment) }
                        .contextMenu {
                            Button("Save…") { download(attachment) }
                        }
                }
            }
            if let errorMessage {
                // A themed danger banner, not `.red`: the danger hue is the
                // host theme's to choose, and a literal red fails contrast on
                // some of them.
                AinkradBanner(message: errorMessage, status: .danger,
                              onDismiss: { self.errorMessage = nil })
            }
        }
    }

    private func chipLabel(_ attachment: MailAttachment) -> String {
        let sizeKB = attachment.size / 1024
        return sizeKB > 0 ? "\(attachment.filename) (\(sizeKB) KB)" : attachment.filename
    }

    /// The default tap action: fetch the bytes on demand (never cached) and
    /// show them via `QLPreviewPanel` rather than immediately forcing a save
    /// dialog — "Save…" is still available from the chip's context menu for
    /// anyone who wants a copy on disk.
    private func preview(_ attachment: MailAttachment) {
        guard downloadingID == nil else { return }
        downloadingID = attachment.attachmentID
        errorMessage = nil
        Task {
            let data = await runtime.fetchAttachment(attachment, messageID: messageID,
                                                     threadID: threadID)
            downloadingID = nil
            guard let data else {
                errorMessage = "Could not download \(attachment.filename)."
                return
            }
            do {
                let file = try AttachmentPreviewFile(data: data, filename: attachment.filename)
                let previewer = QuickLookAttachmentPreviewer(file: file)
                activePreview = previewer
                previewer.show { activePreview = nil }
            } catch {
                errorMessage = "Could not preview \(attachment.filename)."
            }
        }
    }

    private func download(_ attachment: MailAttachment) {
        guard downloadingID == nil else { return }
        downloadingID = attachment.attachmentID
        errorMessage = nil
        Task {
            let data = await runtime.fetchAttachment(attachment, messageID: messageID,
                                                     threadID: threadID)
            downloadingID = nil
            guard let data else {
                errorMessage = "Could not download \(attachment.filename)."
                return
            }
            savePanel(data: data, suggestedName: attachment.filename)
        }
    }

    /// `NSSavePanel` is the one disk write this flow performs, and only after
    /// the user explicitly picks a destination — the fetched bytes otherwise
    /// live only in memory, never in a cache directory.
    private func savePanel(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                Log.mime.error("Failed to write attachment (\(data.count, privacy: .public) bytes) to \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The invite card an incoming `text/calendar` part renders as, in place of
/// the raw ICS text a message used to show. Presents what matters
/// (`ICalendar.parseFirstEvent`'s fields) and, for a `REQUEST`, offers
/// Accept/Tentative/Decline — each of which sends an RSVP reply to the
/// organizer (see `CalendarRSVP`) rather than touching any calendar on this
/// device, which the card says outright so nobody mistakes a tap here for
/// "add to my Calendar".
struct CalendarInviteCard: View {
    let invite: CalendarInvite
    let threadID: String
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    @State private var isSending = false
    @State private var statusMessage: String?
    @State private var respondedWith: CalendarRSVP.PartStat?

    var body: some View {
        // `AinkradSectionFrame` rather than a hand-rolled tinted rectangle: the
        // invite is a distinct titled block inside the message, which is what
        // that component is. It also supplies the chamfer, border and accent
        // tick from the theme, replacing `Color.accentColor` (SwiftUI's own
        // accent, not the host's).
        // `RavenSectionFrame` rather than the kit's `AinkradSectionFrame`
        // for the fill only: this block is nested two surfaces deep (pane,
        // then message card), and the kit's hardcoded 0.35 stacked there is
        // the darkest region in the thread. Everything else about the look
        // — accent tick, chamfer, border, spacing — is unchanged.
        RavenSectionFrame(title: "Invitation") {
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                HStack(spacing: AinkradSpacing.sm) {
                    AinkradIconGlyph(systemName: "calendar", filled: true)
                    Text(invite.summary.isEmpty ? "(no title)" : invite.summary)
                        .font(AinkradFontResolver.font(.body, weight: .semibold, typography: typo))
                        .foregroundStyle(theme.foreground)
                }
                caption(dateLabel)
                if let location = invite.location, !location.isEmpty {
                    caption(location)
                }
                if let organizer = invite.organizer {
                    caption("Organizer: \(organizer.displayLabel)")
                }
                if !invite.attendees.isEmpty {
                    caption("Attendees: "
                            + invite.attendees.map(\.displayLabel).joined(separator: ", "))
                }

                if invite.method == .request {
                    caption("Responding replies to the organizer by email. It does not add "
                            + "this event to any Calendar on this device.")
                    HStack(spacing: AinkradSpacing.sm) {
                        rsvpButton("Accept", .accepted)
                        rsvpButton("Tentative", .tentative)
                        rsvpButton("Decline", .declined)
                    }
                    .padding(.top, AinkradSpacing.xs)
                }
                if let statusMessage {
                    caption(statusMessage)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AinkradFontResolver.font(.caption, typography: typo))
            .foregroundStyle(theme.foreground.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dateLabel: String {
        if invite.isAllDay {
            return invite.start.formatted(date: .abbreviated, time: .omitted) + " (all day)"
        }
        let startText = invite.start.formatted(date: .abbreviated, time: .shortened)
        guard let end = invite.end else { return startText }
        return "\(startText) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func rsvpButton(_ title: String, _ partstat: CalendarRSVP.PartStat) -> some View {
        AinkradButton(title: title, style: respondedWith == partstat ? .primary : .secondary,
                     isLoading: isSending && respondedWith == partstat) {
            respond(partstat)
        }
        .disabled(isSending)
    }

    private func respond(_ partstat: CalendarRSVP.PartStat) {
        guard let thread = runtime.store.thread(threadID),
              let ownAddress = runtime.ownAddress(for: thread.accountID) else {
            statusMessage = "Could not determine which account to reply from."
            return
        }
        guard let reply = CalendarRSVP.makeReply(to: invite, partstat: partstat,
                                                 attendeeEmail: ownAddress, attendeeName: nil)
                .map({ $0.attributed(to: thread.accountID) }) else {
            statusMessage = "This invite has no organizer to reply to."
            return
        }
        isSending = true
        respondedWith = partstat
        statusMessage = nil
        Task {
            do {
                let result = try await runtime.sendThreadReply(reply)
                statusMessage = result.isSent
                    ? "Reply sent to the organizer."
                    : result.message
            } catch {
                statusMessage = "Could not send reply: \(error)."
            }
            isSending = false
        }
    }
}
