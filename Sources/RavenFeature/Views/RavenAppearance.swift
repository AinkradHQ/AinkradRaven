import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// How translucent Raven's own surfaces are. One number, user-controlled from
/// Settings (the Transparency group).
///
/// Why this exists at all: every Raven surface used to take
/// `AinkradPanel`'s default `backgroundOpacity` of 0.94, which is opaque
/// enough that the pane read as a flat dark rectangle pasted on top of the
/// host's translucent island rather than as part of it. The host's backdrop was
/// always there — it simply had nothing to show through 94% of the theme
/// background.
/// So the fix is not "add blur", it is "stop painting over it", and how far to
/// stop is a taste question, which is why it is a setting rather than a new
/// hardcoded number.
///
/// Rune is the precedent, and Raven now follows it exactly: one opacity value,
/// persisted as a document, painted as one flat fill. Rune's terminal sets a
/// translucent background colour and a non-opaque layer and adds NO blur of its
/// own (`TerminalContainerView.apply`), because the host already renders the
/// blurred sky+island backdrop behind any pane whose `chromeFill` is
/// sub-opaque. Raven used to route every surface through `AinkradPanel`, which
/// draws its own `VisualEffectBlur` plus a tint — re-blurring an already-blurred
/// backdrop and adding `.hudWindow`'s light scattering, so the pane body read
/// lighter than the flat title bar. There is nothing left to choose a blur
/// material for, which is why there is no longer a blur setting.
public struct RavenAppearance: Codable, Equatable, Sendable {
    /// How much of the theme background a surface paints over whatever the host
    /// has put behind it, 0-1.
    ///
    /// Always read back through `surfaceOpacity`'s clamp, never used raw — see
    /// `legibleRange` for why the floor is not zero.
    public var rawSurfaceOpacity: Double

    /// The opacity range the UI is allowed to offer, and the clamp every read
    /// passes through.
    ///
    /// The floor is a legibility guarantee, not a taste choice — but it is the
    /// floor at which *this* app's text is still readable, not a generic one.
    /// It used to be 0.45, chosen defensively on the assumption that the
    /// foreground colour is on its own against whatever shows through. It is
    /// not: `ravenLegibleText` puts a contrast-picked halo (see
    /// `RavenLegibleText` — `Color.contrastingText` against the theme's own
    /// foreground, so light text gets a dark halo and dark text a light one)
    /// behind every body and quoted-text run, and `bodyTextOpacity` drives the
    /// glyphs themselves to full strength as the surface thins. With the halo
    /// carrying the contrast, 0.30 is where body text stops being comfortable
    /// — the remaining 30% of theme background is still enough
    /// to keep a bright document behind the window from bleeding through as
    /// texture inside the glyphs (the host's own backdrop blur softens it
    /// further before it ever reaches this fill). Below that the halo starts reading as an
    /// outline rather than as a shadow, which is a legibility cliff as well as
    /// an ugly one, so that is the floor.
    ///
    /// A slider that reached 0 would let a user render their own mail
    /// unreadable in one drag and then not be able to see the setting well
    /// enough to drag it back. The ceiling is 1 so "fully opaque" is still
    /// reachable for anyone who wants the old flat look.
    public static let legibleRange: ClosedRange<Double> = 0.30...1.0

    /// The default: it should read as glass out of the box, because the bug
    /// being fixed is "my panes are opaque" and a default that needs the user
    /// to find a setting has not fixed it.
    ///
    /// 0.72 was the previous value and was wrong twice over: it painted 72% of
    /// a near-black theme background over the backdrop, and message cards then
    /// stacked their own fill on top of that for an effective ~85%. Sitting
    /// just above the new floor rather than in the middle of the range is
    /// deliberate — with the halo doing the legibility work there is no reason
    /// to hedge toward opacity, and the surfaces the user complained about are
    /// exactly the ones this governs.
    public static let defaultSurfaceOpacity: Double = 0.42

    public static let `default` = RavenAppearance(rawSurfaceOpacity: defaultSurfaceOpacity)

    public init(rawSurfaceOpacity: Double = defaultSurfaceOpacity) {
        self.rawSurfaceOpacity = rawSurfaceOpacity
    }

    private enum CodingKeys: String, CodingKey { case rawSurfaceOpacity }

    /// Decoding is written out rather than synthesized so it tolerates BOTH
    /// shapes of the persisted document: the old one, which also carried a
    /// `blur` string (ignored — unknown keys are skipped), and any document
    /// missing `rawSurfaceOpacity` (falls back to the default rather than
    /// throwing). There is a real connected account with a stored appearance;
    /// a decode failure there would silently reset the user's setting.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rawSurfaceOpacity = try container.decodeIfPresent(
            Double.self, forKey: .rawSurfaceOpacity) ?? Self.defaultSurfaceOpacity
    }

    /// The clamped opacity every surface actually uses.
    public var surfaceOpacity: Double {
        min(max(rawSurfaceOpacity, Self.legibleRange.lowerBound), Self.legibleRange.upperBound)
    }

    /// 0 at fully opaque, 1 at the most transparent the range allows. The
    /// interpolation parameter for every contrast compensation below, so they
    /// all move together off one number.
    public var transparency: Double {
        let span = Self.legibleRange.upperBound - Self.legibleRange.lowerBound
        guard span > 0 else { return 0 }
        return (Self.legibleRange.upperBound - surfaceOpacity) / span
    }

    private func lerp(_ atOpaque: Double, _ atClearest: Double) -> Double {
        atOpaque + (atClearest - atOpaque) * transparency
    }

    /// Body-text opacity. Rises toward full as the surface thins out, because
    /// the same 0.9 that reads as comfortably soft on an opaque panel reads as
    /// washed out over a blurred workspace.
    public var bodyTextOpacity: Double { lerp(0.90, 1.0) }

    /// Secondary/caption opacity. Same reasoning, wider swing: dimmed text is
    /// the first thing to become illegible.
    public var secondaryTextOpacity: Double { lerp(0.55, 0.80) }

    // MARK: Stacked layers

    /// What two translucent layers actually add up to: the alpha-compositing
    /// law `1-(1-a)(1-b)`.
    ///
    /// This exists because the previous version of this file did not have it.
    /// The thread pane painted `surfaceOpacity` of the theme background, and a
    /// message card then painted its own fill over *that*, and
    /// the two numbers were picked independently. At the old default the total
    /// was `1-(1-0.72)(1-0.45·0.72)` ≈ 0.85 — the solid slab in the
    /// screenshot. Two translucent layers are not "a bit more translucent than
    /// one"; they multiply.
    public static func composite(_ base: Double, _ layer: Double) -> Double {
        1 - (1 - clampUnit(base)) * (1 - clampUnit(layer))
    }

    /// The inverse: the fill a layer must paint over `base` for the pair to
    /// composite to `target`. Solves `composite(base, x) == target` for `x`.
    ///
    /// Returns 0 when `base` already reaches `target` (a layer cannot subtract
    /// opacity) and when `base` is already 1 (nothing can be added).
    public static func layer(over base: Double, toReach target: Double) -> Double {
        let base = clampUnit(base), target = clampUnit(target)
        guard base < 1, target > base else { return 0 }
        return clampUnit((target - base) / (1 - base))
    }

    private static func clampUnit(_ value: Double) -> Double { min(max(value, 0), 1) }

    /// How much *effective* opacity a card is allowed to add on top of the pane
    /// it sits on — the elevation budget, expressed in the composite's own
    /// units rather than as a fill to paint.
    ///
    /// Small on purpose. A card is distinguished by its chamfer, its accent
    /// border and (unread) its accent edge — see `MessageRow` — not by being a
    /// darker slab. These are absolute, not multiplied by `surfaceOpacity`:
    /// "the card is a touch heavier than its pane" is the same visual
    /// statement at every setting, and the multiply is what produced 0.85.
    public static let readCardLift: Double = 0.05
    public static let unreadCardLift: Double = 0.12

    public func cardLift(isRead: Bool) -> Double {
        isRead ? Self.readCardLift : Self.unreadCardLift
    }

    /// There is deliberately no separate header opacity. `RavenApp.chromeFill`
    /// returns `background.opacity(surfaceOpacity)` — the same expression a
    /// surface paints — so the host's flat `BlockView.headerBackground` and
    /// Raven's flat surface are one fill by construction, exactly as Rune's
    /// are. The `headerFillOpacity` / `headerMaterialCompensation` pair that
    /// used to live here existed only to scale the header down to meet a
    /// blurred body; with the blur gone there is nothing to compensate for.

    /// What a card's region composites to overall: the pane's opacity plus the
    /// card's lift, capped at fully opaque. This is the number the user's
    /// setting is a promise about — surfaces do not silently exceed it.
    public func cardTargetOpacity(isRead: Bool) -> Double {
        min(1, surfaceOpacity + cardLift(isRead: isRead))
    }

    /// The fill a card actually paints, derived from the pane's rather than
    /// chosen next to it. `composite(surfaceOpacity, cardFillOpacity(isRead:))`
    /// equals `cardTargetOpacity(isRead:)` by construction, which is the whole
    /// point and is what `RavenAppearanceTests` pins.
    ///
    /// Nothing in Raven paints a blur, cards least of all: they sit on a flat
    /// translucent pane over the host's already-blurred backdrop, so this
    /// arithmetic is now literally what the screen composites rather than an
    /// approximation of it plus a material's lift.
    public func cardFillOpacity(isRead: Bool) -> Double {
        Self.layer(over: surfaceOpacity, toReach: cardTargetOpacity(isRead: isRead))
    }

    /// A card's border, which is what actually separates it from its pane now
    /// that its fill no longer can. Strengthens as the surface thins, because
    /// that is when the fill contributes least.
    public func cardBorderOpacity(isRead: Bool) -> Double {
        isRead ? lerp(0.22, 0.40) : lerp(0.55, 0.80)
    }

    /// The scrim `RavenTranslucentModal` draws behind the compose overlay.
    /// Fixed, and deliberately not user-scaled: a scrim's job is to push the
    /// mail behind it back, and one that thinned out with the panel would stop
    /// separating the two. Named here because the modal's own fill has to be
    /// computed *over* it — that is the second place two layers stack.
    public static let scrimOpacity: Double = 0.45

    /// A modal's elevation budget over the pane opacity, same idea as
    /// `readCardLift`. Slightly larger than a card's: a modal genuinely is a
    /// separate plane, and it holds editable fields rather than prose.
    public static let modalLift: Double = 0.10

    public var modalTargetOpacity: Double { min(1, surfaceOpacity + Self.modalLift) }

    /// What the compose panel paints — over the scrim, not over nothing. At the
    /// default this is a few percent rather than the kit's hardcoded 0.94.
    /// Zero when the user's setting is already thinner than the scrim, in which
    /// case the scrim alone is the surface and the panel is chamfer + brackets
    /// + border, which is correct rather than a special case.
    public var modalFillOpacity: Double {
        Self.layer(over: Self.scrimOpacity, toReach: modalTargetOpacity)
    }

    /// How strongly to halo body text against whatever is showing through.
    /// Zero at full opacity — an opaque panel needs no help, and a halo there
    /// would just look like a print artifact.
    public var textHaloOpacity: Double { lerp(0.0, 0.55) }
}

/// Owns the persisted `RavenAppearance`.
///
/// A separate `@Observable` object rather than a computed property on
/// `RavenRuntime` for two reasons. It has to be observable: the control lives
/// in the host's settings overlay, which is a different view tree from the
/// Raven pane, so the pane only repaints as the slider moves if the write is
/// something SwiftUI tracks — `RavenRuntime.holdWindow`'s pattern (a computed
/// property straight over `host.documents`) is invisible to observation and
/// would leave the pane stale until it happened to re-render for some other
/// reason. And it keeps `RavenRuntime`, already the largest file here, from
/// growing another stored property and its persistence.
@MainActor @Observable public final class RavenAppearanceStore {
    private let documents: PluginDocumentStore
    private static let key = DocumentKeys.appearance

    /// Write-through: the in-memory value is what views observe, the document
    /// is what survives a relaunch. Persisting on `didSet` rather than making
    /// the getter read the document keeps the read off the disk on every
    /// render pass of every message card.
    public var appearance: RavenAppearance {
        didSet {
            guard appearance != oldValue else { return }
            if let data = try? JSONEncoder().encode(appearance) {
                documents.setData(data, forKey: Self.key)
            }
        }
    }

    public init(documents: PluginDocumentStore) {
        self.documents = documents
        if let data = documents.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(RavenAppearance.self, from: data) {
            self.appearance = stored
        } else {
            // No stored value — the out-of-the-box look, not the extreme of
            // the range.
            self.appearance = .default
        }
    }
}

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
        content.shadow(color: theme.foreground.contrastingText
            .opacity(appearance.textHaloOpacity), radius: 1.5)
    }
}

public extension View {
    /// The Raven pane finish: a flat translucent theme fill at the user's
    /// chosen opacity, with the kit's chamfer, accent edge and glow. No blur —
    /// see `RavenSurface`.
    func ravenSurface(_ appearance: RavenAppearance) -> some View {
        modifier(RavenSurface(appearance: appearance))
    }

    /// Keeps body text readable once the surface under it is translucent. A
    /// no-op at full opacity, and it matters MORE now than it did: a flat 0.42
    /// fill over an arbitrary host backdrop is precisely the case it exists
    /// for.
    func ravenLegibleText(_ appearance: RavenAppearance) -> some View {
        modifier(RavenLegibleText(appearance: appearance))
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

public extension EnvironmentValues {
    var ravenModalPresented: Bool {
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
                    .strokeBorder(theme.accentSecondary.opacity(showsRing ? 0.55 : 0),
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : AinkradMotion.hover, value: showsRing)
    }
}

public extension View {
    /// Subtle, theme-coloured focus indication for a pane, in place of the
    /// system focus ring. Draws nothing while a Raven modal is presented.
    func ravenFocusRing(isFocused: Bool) -> some View {
        modifier(RavenFocusRing(isFocused: isFocused))
    }
}
