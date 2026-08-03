import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// How translucent Raven's own surfaces are, and how the blur behind them is
/// sampled. User-controlled from Settings (the Transparency group).
///
/// Why this exists at all: every Raven surface used to take
/// `AinkradPanel`'s default `backgroundOpacity` of 0.94, which is opaque
/// enough that the pane read as a flat dark rectangle pasted on top of the
/// host's translucent island rather than as part of it. The blur was always
/// there — it simply had nothing to show through 94% of the theme background.
/// So the fix is not "add blur", it is "stop painting over it", and how far to
/// stop is a taste question, which is why it is a setting rather than a new
/// hardcoded number.
///
/// The Terminal pane is the precedent for a user-set surface opacity, and this
/// follows it: one opacity value plus a blur choice, persisted as a document.
public struct RavenAppearance: Codable, Equatable, Sendable {
    /// Which `NSVisualEffectView` material backs Raven's surfaces. Stored as a
    /// string case rather than the kit's `AinkradBlurLevel` because that type
    /// is not `Codable` — it wraps an AppKit material.
    public enum Blur: String, Codable, Sendable, CaseIterable {
        /// `AinkradBlurLevel.panel` — the standard in-app panel material.
        case panel
        /// `AinkradBlurLevel.hud` — a heavier, more diffuse full-screen material.
        case deep

        public var level: AinkradBlurLevel {
            switch self {
            case .panel: return .panel
            case .deep:  return .hud
            }
        }

        public var title: String {
            switch self {
            case .panel: return "Panel"
            case .deep:  return "Deep"
            }
        }
    }

    /// How much of the theme background is painted over the blur, 0-1.
    ///
    /// Always read back through `surfaceOpacity`'s clamp, never used raw — see
    /// `legibleRange` for why the floor is not zero.
    public var rawSurfaceOpacity: Double
    public var blur: Blur

    /// The opacity range the UI is allowed to offer, and the clamp every read
    /// passes through.
    ///
    /// The floor is a legibility guarantee, not a taste choice. Below roughly
    /// 45% the blurred workspace behind the pane — which can be anything,
    /// including a bright document or a light-themed pane — dominates the
    /// composite, and at that point no foreground colour is reliably readable:
    /// the theme's own `foreground` is chosen to contrast with the theme's
    /// `background`, and that assumption stops holding once the background is
    /// mostly not there. A slider that reaches 0 would let a user render their
    /// own mail unreadable in one drag and then not be able to see the setting
    /// well enough to drag it back. The ceiling is 1 so "fully opaque" is
    /// still reachable for anyone who wants the old flat look.
    public static let legibleRange: ClosedRange<Double> = 0.45...1.0

    /// The default: translucent enough to read as glass over the host island,
    /// opaque enough that a long plain-text message is comfortable to read
    /// without touching the setting. Deliberately NOT the bottom of the range
    /// — out of the box this should look right, not maximally transparent.
    public static let defaultSurfaceOpacity: Double = 0.72

    public static let `default` = RavenAppearance(
        rawSurfaceOpacity: defaultSurfaceOpacity, blur: .panel)

    public init(rawSurfaceOpacity: Double = defaultSurfaceOpacity, blur: Blur = .panel) {
        self.rawSurfaceOpacity = rawSurfaceOpacity
        self.blur = blur
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

    /// A message card's own fill, over the already-translucent thread pane.
    ///
    /// Cards deliberately do NOT get their own `VisualEffectBlur`. A blur per
    /// card would mean one `NSVisualEffectView` per message in a `LazyVStack`
    /// — a real cost on a long thread — and it is not needed: the card sits on
    /// a pane that is already blurred, so a semi-transparent theme fill on top
    /// of it reads as glass for free. What the cards needed was to stop being
    /// a near-solid wash, which is what scaling them by `surfaceOpacity` does.
    public func cardOpacity(isRead: Bool) -> Double {
        (isRead ? 0.28 : 0.45) * surfaceOpacity
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

private struct RavenSurface: ViewModifier {
    let appearance: RavenAppearance
    func body(content: Content) -> some View {
        content.ainkradPanel(blur: appearance.blur.level,
                             backgroundOpacity: appearance.surfaceOpacity)
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
    /// The Raven pane finish: the kit's `AinkradPanel`, at the user's chosen
    /// opacity and blur instead of the kit's opaque default.
    func ravenSurface(_ appearance: RavenAppearance) -> some View {
        modifier(RavenSurface(appearance: appearance))
    }

    /// Keeps body text readable once the surface under it is translucent. A
    /// no-op at full opacity.
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
