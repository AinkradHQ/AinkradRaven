import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The app's root view: the inbox+thread split at full height, with one
/// floating compose affordance over it.
///
/// There is deliberately no surface switcher. The old `Inbox | Compose`
/// segmented picker had exactly two segments, one of which ("Inbox") was the
/// only thing the app is for and so was never a real choice, and the other of
/// which now opens as an overlay instead of replacing the whole app. A picker
/// whose every segment is either the default or a modal is chrome, not
/// navigation.
///
/// Composing is ONE surface. Reply/Reply-all/Forward used to be an inline panel
/// pinned to the bottom of the thread and new mail a full-screen surface, which
/// meant two layouts, two send paths, and two places a draft could be lost.
/// Both now present the same `ComposeSurface` in the same overlay, differing
/// only by the `ComposeContext` handed to it.
public struct RavenShell: View {
    let runtime: RavenRuntime

    /// What the overlay is composing, or `nil` when it is closed. A single
    /// optional rather than a Bool plus a payload, so "open" and "what it is
    /// composing" cannot disagree.
    @State private var composing: ComposeContext?

    /// The width of the inbox pane. A fixed rail, not a fraction: a thread list
    /// that grows with the window ends up with rows of mostly empty space,
    /// while the reading pane is the part that genuinely benefits from width.
    private static let inboxWidth: CGFloat = 360

    public init(runtime: RavenRuntime) { self.runtime = runtime }

    /// Bridges the optional above to the Bool the kit's overlay modifiers take.
    ///
    /// Setting it false clears `composing`, which closes the overlay — and
    /// deliberately does NOT touch `DraftBox`. The "a draft is removed if and
    /// only if the message was sent" invariant means a dismissed composer's
    /// text must survive; `ComposeSurface` saves its own draft on the way out,
    /// so the next open finds it in the Drafts list.
    private var isComposing: Binding<Bool> {
        Binding(get: { composing != nil }, set: { if !$0 { composing = nil } })
    }

    public var body: some View {
        // A root-level `GeometryReader` purely to size the compose overlay
        // against the room actually available. The shell already fills both
        // axes, so this changes nothing about the split's own layout — and it is
        // the shell, not the composer, that chooses `contentWidth`, so this is
        // where the measurement belongs.
        GeometryReader { proxy in
            split(availableWidth: proxy.size.width)
        }
    }

    private func split(availableWidth: CGFloat) -> some View {
        HStack(spacing: AinkradSpacing.sm) {
            InboxSurface(model: runtime.model, runtime: runtime)
                .frame(width: Self.inboxWidth)
            ThreadSurface(model: runtime.model, runtime: runtime,
                          onCompose: { composing = $0 })
                .frame(maxWidth: .infinity)
        }
        .padding(AinkradSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { composeButton }
        // `.ainkradModal(isPresented:contentWidth:)`, not `.ainkradSheet`: a
        // composer is a focused, self-contained task with To/Cc/Subject/body
        // fields and a drafts rail, so it needs a real content width — and the
        // `contentWidth:` overload is the one where the number passed is the
        // width the content actually gets (the bare `ainkradModal` pads first
        // and then caps the padded result at 480, which is narrower than a
        // recipient row wants). A sheet is edge-anchored and full-bleed on its
        // cross axis, which suits a filter or a detail drawer, not a form the
        // user will spend a minute inside.
        .ainkradModal(isPresented: isComposing,
                     contentWidth: Self.composeWidth(in: availableWidth)) {
            if let composing {
                ComposeSurface(runtime: runtime, context: composing,
                              // Below the threshold the rail is dropped rather
                              // than squeezed: at that width it would be taking
                              // room from the fields the user is actually typing
                              // into, and the drafts it lists are still reachable
                              // by reopening the composer.
                              showsDraftsRail:
                                Self.composeWidth(in: availableWidth) >= Self.draftsRailMinWidth,
                              onClose: { self.composing = nil })
                    // `maxHeight`, not a fixed height: the modal is scoped to
                    // this view's bounds, and a fixed 520 would overflow a
                    // short window (Raven runs in the host's overlay
                    // presentation as well as a full pane).
                    .frame(maxHeight: Self.composeHeight)
            }
        }
    }

    /// Wide enough for the drafts rail plus a composer that does not wrap a
    /// typical recipient list, and short enough to leave the scrim visible so
    /// the overlay still reads as sitting above the mail rather than replacing
    /// it — but never wider than the room there actually is. Raven runs in the
    /// host's overlay presentation as well as a full pane, and a flat 780 there
    /// pushed the panel border over its own content.
    private static let idealComposeWidth: CGFloat = 780
    /// The floor: below this the overlay stops shrinking and simply uses what
    /// there is, because a composer narrower than this is unusable either way.
    private static let minComposeWidth: CGFloat = 360
    /// The width at which the drafts rail earns its 220pt.
    private static let draftsRailMinWidth: CGFloat = 660
    private static let composeHeight: CGFloat = 520

    static func composeWidth(in availableWidth: CGFloat) -> CGFloat {
        // The scrim has to stay visible on both edges, hence the inset — the
        // overlay must read as sitting above the mail, not replacing it.
        let usable = availableWidth - 2 * AinkradSpacing.xl
        guard usable > 0 else { return minComposeWidth }
        return max(minComposeWidth, min(idealComposeWidth, usable))
    }

    /// The floating compose affordance: the kit's own `AinkradIconButton`
    /// inside a chamfered, glowing plate, so it is the same HUD language as
    /// every other floating surface rather than a bespoke Material circle.
    /// Every colour comes from the theme — see `ComposeFloatingButton`.
    private var composeButton: some View {
        ComposeFloatingButton { composing = .new }
            .padding(AinkradSpacing.lg)
    }
}

/// The bottom-trailing compose button.
///
/// Not a circle: Cardinal HUD's affordances are chamfered, and a lone round
/// button beside chamfered panels reads as borrowed from another product. The
/// glyph itself is `AinkradIconButton` — the kit's icon button, with its own
/// hover and tooltip behaviour — and this type only supplies the raised plate
/// underneath it.
private struct ComposeFloatingButton: View {
    let action: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @State private var hovering = false

    private static let size: CGFloat = 52

    var body: some View {
        // `AinkradIconButton(systemName:size:tooltip:)` already draws the
        // chamfered plate, border, hover fill and accent glow, all scaled off
        // `size` — this adds only the accent-tinted riser that makes it read as
        // FLOATING above the panes rather than as one more toolbar glyph.
        // Nothing here re-implements the button's own chrome.
        AinkradIconButton(systemName: "square.and.pencil", size: Self.size,
                          tooltip: "Compose (new message)", action: action)
            .background(
                // Every colour from the theme, including the lift: a fixed
                // black shadow vanishes on a light theme, so the riser is the
                // theme's own accent at low opacity.
                ChamferShape(cut: Self.size * 0.2)
                    .fill(theme.accentPrimary.opacity(hovering ? 0.30 : 0.18))
                    .shadow(color: theme.accentSecondary.opacity(hovering ? 0.45 : 0.28),
                            radius: hovering ? 14 : 8, x: 0, y: 2)
            )
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : AinkradMotion.hover, value: hovering)
    }
}
