import SwiftUI
import AppKit
import AinkradAppKit
import AinkradAppKitUI

/// `.ainkradModal(isPresented:contentWidth:)` with the panel's translucency
/// taken from the user's setting instead of the kit's fixed 0.94.
///
/// Why this is local rather than a call into the kit: `AinkradModalModifier`
/// builds its panel with `.ainkradPanel(showsBrackets: true)`, which takes
/// `AinkradPanel`'s default `backgroundOpacity` of 0.94, and exposes no way to
/// change it. That is exactly the "flat opaque slab" the composer screenshot
/// shows — the scrim behind it blurs correctly and then the panel paints 94% of
/// the theme background over the result. Adding a `backgroundOpacity:`
/// parameter to `.ainkradModal` is the right fix and would let this file be
/// deleted, but the kit is pinned to the exact revision the host builds
/// against, so changing it here would mean a plugin linking a kit the host does
/// not have.
///
/// Everything else is a faithful copy of the kit modifier, on purpose: the
/// scrim blur and dim, dismissal on scrim tap, the invisible Esc button, the
/// materialize/scale transition and its `ainkradReduceMotion` gate, and the
/// cap-then-pad content sizing that makes the `contentWidth` argument mean the
/// width the content actually gets. Dismissal behaviour is unchanged, which
/// matters more here than anywhere else in Raven: closing the composer must
/// keep routing through the same `isPresented` write, because
/// `ComposeSurface.onDisappear` is what preserves the draft, and the "a draft
/// is removed if and only if the message was sent" invariant depends on that
/// path being the only one.
private struct RavenTranslucentModalModifier<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var contentWidth: CGFloat
    var appearance: RavenAppearance
    @ViewBuilder var modalContent: () -> ModalContent

    @Environment(\.ainkradReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    VisualEffectBlur(level: appearance.blur.level, blendingMode: .withinWindow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(0.6)
                    // The scrim. Unchanged from the kit's 0.45 and deliberately
                    // NOT scaled by the transparency setting: a scrim's whole
                    // job is to push the content behind it back, and a scrim
                    // that thins out with the panel would stop separating the
                    // two. This is the layer the old focus ring was being drawn
                    // on top of — see `RavenFocusRing`.
                    Color.black.opacity(0.45)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }

                    modalContent()
                        .frame(maxWidth: contentWidth)
                        .padding(AinkradSpacing.lg)
                        .ainkradPanel(blur: appearance.blur.level,
                                      backgroundOpacity: appearance.surfaceOpacity,
                                      showsBrackets: true)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.94, anchor: .center).combined(with: .opacity)
                        )

                    dismissKey
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : AinkradMotion.materialize, value: isPresented)
            }
        }
    }

    /// Invisible Esc-key dismiss affordance, copied from the kit modifier: a
    /// real zero-size, zero-opacity `Button` rather than any native menu
    /// chrome, so Esc dismisses while this scoped overlay is key.
    private var dismissKey: some View {
        Button("") { isPresented = false }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A centered modal scoped to this view's bounds, at the user's chosen
    /// surface translucency. `contentWidth` is the width the CONTENT gets.
    ///
    /// Also publishes `ravenModalPresented` into the subtree it is attached to,
    /// so panes underneath can stand their focus indication down while a scrim
    /// is over them — one presentation state, read from one place, rather than
    /// each pane guessing.
    func ravenTranslucentModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        contentWidth: CGFloat,
        appearance: RavenAppearance,
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        self
            .environment(\.ravenModalPresented, isPresented.wrappedValue)
            .modifier(RavenTranslucentModalModifier(
                isPresented: isPresented, contentWidth: contentWidth,
                appearance: appearance, modalContent: content))
    }
}
