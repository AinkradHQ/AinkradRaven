import AinkradAppKit
import AinkradAppKitUI
import SwiftUI

/// `AinkradSectionFrame`'s look, with an appearance-derived fill instead of its
/// hardcoded one.
///
/// The kit component hardcodes `theme.surfaceElevated.opacity(0.35)` and lives
/// in the pinned SDK, so it cannot be changed here. 0.35 is a sensible number
/// for a titled block on an opaque settings page and the wrong one for a block
/// inside a pane that is already only 42% painted: `composite(0.42, 0.35)` is
/// 0.62, a fifth of the way to solid over its own surroundings, and the block
/// reads as a dark card pasted onto glass.
///
/// So this reproduces the component — the accent tick, the uppercase tracked
/// title, the chamfer, the accent hairline, `AinkradSpacing.md` padding, all of
/// it — and changes only the fill, to the same `cardFillOpacity` budget every
/// other Raven surface spends. Nothing else about the look differs, which is
/// the point: it must still read as one component family with the kit's.
///
/// Used where translucency matters (inside the thread pane, the inbox rail and
/// the compose overlay). Raven's SETTINGS views deliberately keep the kit's
/// `AinkradSectionFrame`: those render inside the host's own settings chrome,
/// which is opaque, so there is nothing there for a fill to obscure and using
/// the kit component keeps them identical to every other app's settings page.
struct RavenSectionFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ravenAppearance) private var appearance

    var body: some View {
        // The kit's `accentTick` role for the tick. The section frame's own
        // component tokens (tick size, title colour) are not public, so those
        // come from the ladders at the kit's values.
        let tick = skin.roles.accentTick
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack(spacing: AinkradSpacing.xs) {
                Rectangle()
                    .fill(skin.color(tick.fill))
                    .frame(width: skin.size.s14, height: skin.size.s2)
                    .shadow(color: skin.color(tick.glow.color.rest), radius: tick.glow.radius.rest)
                Text(title.uppercased())
                    .font(AinkradFontResolver.font(.caption, weight: .semibold, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o70))
                    .tracking(1.2)
            }
            content()
        }
        .padding(AinkradSpacing.md)
        // The one difference from the kit component. `isRead: false` — the
        // larger of the two lifts — because a titled block is a deliberate
        // grouping and has to be findable, the same call `InboxRow` makes for
        // a hovered row.
        .background(
            skin.shape(cut: AinkradRadius.md)
                .fill(theme.surfaceElevated.opacity(appearance.cardFillOpacity(isRead: false)))
        )
        .overlay(
            skin.shape(cut: AinkradRadius.md)
                .strokeBorder(
                    theme.accentSecondary
                        .opacity(appearance.cardBorderOpacity(isRead: true)), lineWidth: 1))
    }
}
