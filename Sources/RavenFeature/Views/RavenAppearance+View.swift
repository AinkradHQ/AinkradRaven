import AinkradAppKit
import AinkradAppKitUI
import SwiftUI

// MARK: - Applying it

/// The Ainkrad panel finish MINUS the blur: theme background at the user's
/// opacity, chamfered clip, accent edge, panel glow.
///
/// This is `AinkradPanel`'s body with its `VisualEffectBlur` removed, and the
/// removal is the whole point rather than an optimisation. The host already
/// renders one shared blurred sky+island backdrop behind any pane whose
/// `chromeFill` is sub-opaque; a `VisualEffectBlur(.withinWindow)` here
/// re-blurs that and, because `.hudWindow` scatters light, lifts the result —
/// which is what made the pane body read lighter than its flat title bar. Rune
/// paints one flat translucent fill for the same reason (see
/// `TerminalContainerView`: "The layer must be non-opaque", and it adds no blur
/// of its own).
///
/// At full opacity there is nothing behind to sample either, so there is one
/// path, not two.
private struct RavenSurface: ViewModifier {
    let appearance: RavenAppearance
    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(theme.background.opacity(appearance.surfaceOpacity))
            .clipShape(ChamferShape(cut: AinkradRadius.panel))
            .overlay(
                ChamferShape(cut: AinkradRadius.panel)
                    .strokeBorder(theme.accentSecondary.opacity(0.4), lineWidth: 1)
            )
            .ainkradPanelGlow()
    }
}

private struct RavenLegibleText: ViewModifier {
    let appearance: RavenAppearance
    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        // `Color.contrastingText` (the kit's `ColorContrast`) picked against
        // the FOREGROUND, so the halo is always the opposite of the text it
        // protects: light text gets a dark halo, dark text a light one. That
        // holds for any host theme without this code knowing which one is
        // active, which is the whole reason to ask the kit rather than
        // hardcode black.
        content.shadow(
            color: theme.foreground.contrastingText
                .opacity(appearance.textHaloOpacity), radius: 1.5)
    }
}

extension View {
    /// The Raven pane finish: a flat translucent theme fill at the user's
    /// chosen opacity, with the kit's chamfer, accent edge and glow. No blur —
    /// see `RavenSurface`.
    public func ravenSurface(_ appearance: RavenAppearance) -> some View {
        modifier(RavenSurface(appearance: appearance))
    }

    /// Keeps body text readable once the surface under it is translucent. A
    /// no-op at full opacity, and it matters MORE now than it did: a flat 0.42
    /// fill over an arbitrary host backdrop is precisely the case it exists
    /// for.
    public func ravenLegibleText(_ appearance: RavenAppearance) -> some View {
        modifier(RavenLegibleText(appearance: appearance))
    }
}

// MARK: - Carrying it down the tree

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

extension EnvironmentValues {
    public var ravenAppearance: RavenAppearance {
        get { self[RavenAppearanceKey.self] }
        set { self[RavenAppearanceKey.self] = newValue }
    }
}

extension View {
    /// Publishes the surface setting to every Raven surface below this point.
    public func ravenAppearanceEnvironment(_ appearance: RavenAppearance) -> some View {
        environment(\.ravenAppearance, appearance)
    }
}

// MARK: - Focus, and not painting over a modal

/// True while a Raven-owned modal is covering this subtree.
///
/// Exists so a pane's focus ring can stand down: a scrim is there to push
/// content behind it, and a focus ring drawn brighter than the modal it sits
/// under inverts that. `RavenShell` sets it while the compose overlay is up.
private struct RavenModalPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var ravenModalPresented: Bool {
        get { self[RavenModalPresentedKey.self] }
        set { self[RavenModalPresentedKey.self] = newValue }
    }
}

/// A restrained, theme-coloured keyboard-focus indicator for a pane.
///
/// Replaces the system focus ring that `.focusable()` draws. That ring is
/// drawn by AppKit in the system accent colour at full strength around the
/// pane's bounds, which in a HUD made of chamfered accent-stroked panels reads
/// as an error state rather than as focus — and, because it is painted by the
/// focused view itself, it stayed visible and full-brightness on top of the
/// compose overlay's scrim, brighter than the modal it was behind.
///
/// This draws instead: the panel's own chamfer, in the theme's secondary
/// accent, at a fraction of the strength of the panel's normal edge, and only
/// while the pane genuinely holds keyboard focus and nothing is presented over
/// it.
private struct RavenFocusRing: ViewModifier {
    let isFocused: Bool
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.ravenModalPresented) private var modalPresented

    /// Focus is only worth showing when it is real AND nothing is covering it.
    private var showsRing: Bool { isFocused && !modalPresented }

    func body(content: Content) -> some View {
        content
            // Suppress AppKit's own ring; this modifier is its replacement.
            .focusEffectDisabled()
            .overlay {
                ChamferShape(cut: AinkradRadius.panel)
                    .strokeBorder(
                        theme.accentSecondary.opacity(showsRing ? 0.55 : 0),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : AinkradMotion.hover, value: showsRing)
    }
}

extension View {
    /// Subtle, theme-coloured focus indication for a pane, in place of the
    /// system focus ring. Draws nothing while a Raven modal is presented.
    public func ravenFocusRing(isFocused: Bool) -> some View {
        modifier(RavenFocusRing(isFocused: isFocused))
    }
}
