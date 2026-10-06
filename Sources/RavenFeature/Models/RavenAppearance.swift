import Foundation

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
        self.rawSurfaceOpacity =
            try container.decodeIfPresent(
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
        let base = clampUnit(base)
        let target = clampUnit(target)
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
