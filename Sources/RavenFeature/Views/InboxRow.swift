import SwiftUI
import AppKit
import AinkradAppKit
import AinkradAppKitUI

/// One thread row in the inbox rail.
///
/// Extracted from `InboxSurface` and given explicit line limits, which is the
/// whole reason it is no longer an `AinkradListRow`.
///
/// The rail is a fixed 360pt, and `AinkradListRow` applies no `lineLimit` to
/// either of its two text slots, so a long subject wrapped to three lines and a
/// snippet — which is a whole paragraph of the message, not a one-liner — ran
/// to seven. A single row could take a third of the rail, which makes the list
/// unscannable: the point of a mail list is that the eye moves down a column of
/// same-shaped rows, and rows that each pick their own height destroy that.
///
/// The kit component cannot express this: the fix needs DIFFERENT limits for
/// the title and the subtitle (one line and two), and `.lineLimit` applied to
/// `AinkradListRow` from outside is an environment value that would clamp both
/// to the same number. So the row is local, and it reproduces only
/// `AinkradListRow`'s state treatment — leading accent bar on
/// hover/selection, chamfered fill, no divider lines — deliberately, so it
/// still reads as the same component family. Giving `AinkradListRow` optional
/// line limits is the better long-term fix and is a kit change, not a Raven
/// one.
///
/// Height is constant by construction: one title line plus two subtitle lines
/// with `reservesSpace: true`, so a one-word snippet occupies the same height
/// as a three-sentence one and the column stays even. Reserving the space is
/// the point — clamping alone would still leave short rows shorter and the
/// ragged column the clamp was supposed to fix.
struct InboxRow: View {
    let summary: ThreadSummary
    let isSelected: Bool
    let isUnread: Bool
    /// The live surface setting, so a row's hover/selection fill is derived
    /// from the rail's own translucency instead of being a fixed wash on top of
    /// it — the same `cardFillOpacity` arithmetic the thread's message cards
    /// use. Without this the rail was glass and its rows were stone.
    let appearance: RavenAppearance
    /// Rendered under the date. Passed in rather than derived here because
    /// which badges apply is `InboxSurface`'s knowledge (how many accounts are
    /// connected, whether the list is filtered, what the row's last error was).
    let accountLabel: String?
    let rowError: String?
    let onTap: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// Subject: exactly one line. A subject is an identifier, not content —
    /// the second line of a wrapped one is never what tells you which thread
    /// this is.
    private static let subjectLines = 1
    /// Sender + snippet: two, which is enough to tell two similar threads
    /// apart and not enough to bury the next row.
    private static let snippetLines = 2

    private var accentWidth: CGFloat { isSelected || hovering ? 2 : 0 }

    var body: some View {
        HStack(spacing: AinkradSpacing.md) {
            // Starred wins over unread in the glyph because it is the state the
            // user set deliberately; unread is still carried by the filled
            // treatment and the bold subject.
            AinkradIconGlyph(systemName: leadingGlyph, filled: isUnread)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.subject.isEmpty ? "(no subject)" : summary.subject)
                    .font(AinkradFontResolver.font(
                        .body, weight: isUnread ? .semibold : .medium, typography: typo))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(Self.subjectLines)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.55))
                    .lineLimit(Self.snippetLines, reservesSpace: true)
                    .truncationMode(.tail)
            }
            // Without this the VStack takes its ideal width from the untruncated
            // strings and pushes the trailing column off the rail; the line
            // limits alone do not constrain width.
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, AinkradSpacing.md)
        .padding(.vertical, AinkradSpacing.sm)
        .background(ChamferShape(cut: 6).fill(rowFill))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.accentSecondary)
                .frame(width: accentWidth)
                .shadow(color: theme.accentSecondary.opacity(isSelected ? 0.6 : 0), radius: 3)
        }
        .clipShape(ChamferShape(cut: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: hovering)
        .onTapGesture(perform: onTap)
    }

    /// Date on top, state badges under it. `.top` alignment so the date lines
    /// up with the subject rather than floating in the middle of a now-taller
    /// row.
    private var trailing: some View {
        VStack(alignment: .trailing, spacing: AinkradSpacing.xs) {
            Text(MailDateLabel.short(for: summary.lastMessageDate))
                .font(AinkradFontResolver.font(.caption, typography: typo))
                .foregroundStyle(theme.foreground.opacity(isUnread ? 0.85 : 0.5))
                .monospacedDigit()
                .lineLimit(1)
            HStack(spacing: AinkradSpacing.xs) {
                if let rowError {
                    AinkradBadge(text: "!", status: .danger).ainkradTooltip(rowError)
                }
                if let accountLabel {
                    AinkradBadge(text: accountLabel, status: .neutral)
                }
                if isUnread {
                    AinkradBadge(text: "\(summary.unreadCount)", status: .success)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Selection stays an accent tint — an accent is not a dark layer, so it
    /// does not fight the rail's translucency and reads at any setting. Hover
    /// is the one that had to change: a flat 0.5 of `surfaceElevated` over an
    /// already-translucent rail composited to a near-solid row.
    private var rowFill: Color {
        if isSelected { return theme.accentPrimary.opacity(0.16) }
        if hovering {
            return theme.surfaceElevated.opacity(appearance.cardFillOpacity(isRead: false))
        }
        return .clear
    }

    private var leadingGlyph: String {
        if summary.isStarred { return "star.fill" }
        return isUnread ? "envelope.badge" : "envelope.open"
    }

    /// Sender first, then the snippet. Sender leads because it is the fact most
    /// often used to decide whether to open a thread, and because it is short
    /// enough to survive the two-line clamp even when the snippet does not.
    private var subtitle: String {
        let sender = summary.participants.first?.displayLabel ?? "Unknown sender"
        return summary.snippet.isEmpty ? sender : "\(sender) — \(summary.snippet)"
    }
}
