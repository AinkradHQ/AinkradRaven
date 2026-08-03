import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The user's surface setting, carried down the view tree.
///
/// Why an environment value when `InboxRow` and `ComposeUndoBanner` take it as
/// a `let`: those are constructed by a view that already holds the runtime, so
/// passing it costs one argument. The surfaces fixed here — a recipient
/// suggestion popover, a chip field's well, a titled block inside a message —
/// are three and four levels down from the nearest view that has a runtime, and
/// threading an argument through every intermediate initialiser to reach them
/// is how a translucency rule gets forgotten at one site (which is exactly what
/// happened: `ComposeFields` took `AinkradPanel`'s opaque 0.94 default because
/// nothing there had an `appearance` to hand).
///
/// The default is `RavenAppearance.default`, NOT the kit's opaque look, so a
/// site that is somehow reached without an injection is still glass at the
/// out-of-the-box setting rather than a slab.
///
/// Observation still works: `RavenShell` sets it from
/// `runtime.appearanceStore.appearance` inside its own `body`, so the read is
/// tracked and dragging the slider re-injects.
private struct RavenAppearanceKey: EnvironmentKey {
    static let defaultValue = RavenAppearance.default
}

public extension EnvironmentValues {
    var ravenAppearance: RavenAppearance {
        get { self[RavenAppearanceKey.self] }
        set { self[RavenAppearanceKey.self] = newValue }
    }
}

public extension View {
    /// Publishes the surface setting to every Raven surface below this point.
    func ravenAppearanceEnvironment(_ appearance: RavenAppearance) -> some View {
        environment(\.ravenAppearance, appearance)
    }
}

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
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ravenAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack(spacing: AinkradSpacing.xs) {
                Rectangle()
                    .fill(theme.accentSecondary)
                    .frame(width: 14, height: 2)
                    .shadow(color: theme.accentSecondary.opacity(0.6), radius: 2)
                Text(title.uppercased())
                    .font(AinkradFontResolver.font(.caption, weight: .semibold, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.7))
                    .tracking(1.2)
            }
            content()
        }
        .padding(AinkradSpacing.md)
        // The one difference from the kit component. `isRead: false` — the
        // larger of the two lifts — because a titled block is a deliberate
        // grouping and has to be findable, the same call `InboxRow` makes for
        // a hovered row.
        .background(ChamferShape(cut: AinkradRadius.md)
            .fill(theme.surfaceElevated.opacity(appearance.cardFillOpacity(isRead: false))))
        .overlay(ChamferShape(cut: AinkradRadius.md)
            .strokeBorder(theme.accentSecondary
                .opacity(appearance.cardBorderOpacity(isRead: true)), lineWidth: 1))
    }
}
