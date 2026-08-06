import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The drafts rail beside the composer.
///
/// `version` is passed in rather than owned here: `DraftBox` is a plain
/// in-memory box, not an `@Observable` type, so nothing re-reads it on its own.
/// The composer bumps its own counter after every draft mutation (including the
/// removal a successful send performs), and a change to this parameter is what
/// makes the list re-read. Owning the counter locally would leave the rail stale
/// exactly when a send had just emptied it.
///
/// Shown only when there is at least one draft — `ComposeSurface.showsRail`
/// decides, so there is no empty state here. The old one was a sentence saying
/// nothing was saved yet, occupying a 220pt column of a brand-new composer; no
/// rail says the same thing without spending the width.
///
/// The `maxHeight: .infinity` is INSIDE the `AinkradSectionFrame`, on its
/// content. Applied outside it, the frame stretched to the column's height while
/// the chamfered card inside stayed its natural size and centred — a card
/// floating in dead space, which is what it was doing.
struct ComposeDraftsRail: View {
    let version: Int
    let selectedDraftID: String?
    let onSelect: (String, OutgoingMessage) -> Void
    let onDelete: (String) -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        // `RavenSectionFrame`, not the kit's: this block sits inside the
        // compose overlay, and the kit component's hardcoded 0.35 of
        // `surfaceElevated` composites over the panel to a dark card in the
        // middle of glass. Same look, appearance-derived fill.
        RavenSectionFrame(title: "Drafts") {
            let drafts = { _ = version; return DraftBox.shared.all() }()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(drafts, id: \.id) { entry in
                        AinkradListRow(
                            isSelected: selectedDraftID == entry.id,
                            onTap: { onSelect(entry.id, entry.message) },
                            leading: {
                                // A threaded draft is a reply waiting to be
                                // finished, which is a different thing from
                                // an unsent new message.
                                AinkradIconGlyph(systemName: entry.message.threadID == nil
                                                 ? "doc.text" : "arrowshape.turn.up.left")
                            },
                            title: entry.message.subject.isEmpty
                                ? "(no subject)" : entry.message.subject,
                            subtitle: entry.message.to.first?.displayLabel,
                            trailing: {
                                AinkradIconButton(systemName: "trash", size: 22,
                                                  tooltip: "Delete draft") {
                                    onDelete(entry.id)
                                }
                            })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The live undo-send countdown shown right after a send is queued.
///
/// Live, not static: a `TimelineView` redraws this once a second so the
/// remaining time actually counts down instead of being frozen at whatever it
/// read when the banner first appeared.
///
/// `AinkradMeter` — a determinate radial gauge driven by `value`/`total` — is
/// the kit's existing countdown affordance and is reused rather than a bespoke
/// ring being built.
struct ComposeUndoBanner: View {
    let deadline: Date
    /// The full hold window, so the gauge has a total to be a fraction of.
    let holdWindow: TimeInterval
    /// Same reason `InboxRow` takes it: this banner sits INSIDE the compose
    /// modal, whose own fill is now a few percent, so a fixed 0.5 wash here
    /// would be the most solid thing on screen. Derived from the setting
    /// instead.
    let appearance: RavenAppearance
    let onUndo: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            HStack(spacing: AinkradSpacing.sm) {
                AinkradMeter(value: remaining, total: max(holdWindow, 1),
                            label: "undo", size: 36)
                Text("Sending in \(Int(remaining.rounded(.up)))s…")
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.7))
                AinkradButton(title: "Undo", style: .secondary, action: onUndo)
            }
            .padding(AinkradSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChamferShape(cut: AinkradRadius.sm)
                .fill(theme.surfaceElevated
                    .opacity(appearance.cardFillOpacity(isRead: false))))
            .overlay(ChamferShape(cut: AinkradRadius.sm)
                .strokeBorder(theme.accentSecondary
                    .opacity(appearance.cardBorderOpacity(isRead: false)), lineWidth: 1))
        }
    }
}

/// The composer's title row: what is being composed, and the close button.
///
/// A reply and a forward look identical once the fields are filled, and the
/// difference — whether the recipient sees it inside the original conversation —
/// matters enough to name. The close button says outright that closing keeps the
/// draft, because a composer that can be dismissed by tapping the scrim needs to
/// promise that in words, not just in behaviour.
struct ComposeTitleBar: View {
    let context: ComposeContext
    let isEditingDraft: Bool
    let onClose: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconGlyph(systemName: glyph, filled: true)
            Text(title)
                .font(AinkradFontResolver.font(.headline, weight: .medium, typography: typo))
                .foregroundStyle(theme.foreground)
            Spacer(minLength: AinkradSpacing.sm)
            AinkradIconButton(systemName: "xmark", size: 24,
                              tooltip: "Close (your draft is kept)", action: onClose)
        }
    }

    private var title: String {
        switch context {
        case .new: return isEditingDraft ? "Draft" : "New message"
        case .reply(let mode, _):
            switch mode {
            case .reply: return "Reply"
            case .replyAll: return "Reply to all"
            case .forward: return "Forward"
            }
        }
    }

    private var glyph: String {
        switch context {
        case .new: return "square.and.pencil"
        case .reply(let mode, _):
            return mode == .forward ? "arrowshape.turn.up.right" : "arrowshape.turn.up.left"
        }
    }
}
