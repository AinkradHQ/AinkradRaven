import AinkradAppKit
import AinkradAppKitUI
import SwiftUI

/// `.ainkradModal(isPresented:contentWidth:)` with the panel's translucency
/// taken from the user's setting instead of the kit's fixed 0.94.
///
/// The kit modal draws its panel with `AinkradPanel`, which reads its fill and
/// blur from `\.ainkradSurfaceOpacity` and `\.ainkradSurfaceBlur`. This sets
/// them to `modalFillOpacity` and no blur: the panel sits over the scrim, and
/// painting the pane's opacity over the 0.45 scrim composited to ~0.85, the
/// flat composer. `modalFillOpacity` makes the stack land on the user's setting
/// plus one modal lift. No blur because the panel's own `VisualEffectBlur` would
/// be a third blur over an already-blurred scrim over the host's backdrop.
///
/// An environment write reaches everything below it, which here is both the
/// view the modal is attached to and the modal's content. Both get the values
/// in force above this point back, so only the modal panel takes the setting:
/// a kit panel or modal inside either keeps the host's.
///
/// Dismissal is the kit's: scrim tap and Esc both write `isPresented`. That
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

    @Environment(\.ainkradSurfaceOpacity) private var outerOpacity
    @Environment(\.ainkradSurfaceBlur) private var outerBlur

    func body(content: Content) -> some View {
        content
            .environment(\.ainkradSurfaceOpacity, outerOpacity)
            .environment(\.ainkradSurfaceBlur, outerBlur)
            .ainkradModal(isPresented: $isPresented, contentWidth: contentWidth) {
                modalContent()
                    .environment(\.ainkradSurfaceOpacity, outerOpacity)
                    .environment(\.ainkradSurfaceBlur, outerBlur)
            }
            .environment(\.ainkradSurfaceOpacity, appearance.modalFillOpacity)
            .environment(\.ainkradSurfaceBlur, false)
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
            .modifier(
                RavenTranslucentModalModifier(
                    isPresented: isPresented, contentWidth: contentWidth,
                    appearance: appearance, modalContent: content))
    }
}
