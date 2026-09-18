import SwiftUI
import AinkradAppKit

/// Raven's **basic** mode: read the inbox, open a thread. No composing.
///
/// Reading and writing mail are different jobs, and most opens are the first
/// one. Basic keeps `InboxSurface` and `ThreadSurface` — the two panes that ARE
/// reading — and drops everything the composer needs.
///
/// Honest about the size of the win: the compose stack
/// (`ComposeSurface`, `ComposeDraftsRail`, `ComposeRichEditor`,
/// `ComposeFormatBar`, `ComposeRecipients`, `ComposeAdviceView`) already lives
/// behind a modal, so advanced does not build it until you ask either. What
/// basic actually removes is the compose button, the modal wrapper, and the
/// `ComposeDraftPublisher` observation that can raise the composer from under
/// you when the agent drafts something. So this is a **navigational** win —
/// a surface with one job — not a startup-cost one. The eager cost in Raven is
/// `RavenRuntime`, which both modes share.
///
/// Replying escalates instead of being hidden: a reply IS composing, and the
/// mode that composes is advanced.
struct RavenBasicView: View {
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSetPaneMode) private var setPaneMode

    /// A fixed rail for the same reason `RavenShell` uses one: a thread list
    /// that grows with the window is mostly empty space, and width belongs to
    /// the pane being read.
    private static let inboxWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: AinkradSpacing.sm) {
            InboxSurface(model: runtime.model, runtime: runtime)
                .frame(width: Self.inboxWidth)
            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    AinkradModeSwitch()
                }
                .padding(.horizontal, AinkradSpacing.sm)
                ThreadSurface(model: runtime.model, runtime: runtime,
                              // Reply escalates rather than opening a composer
                              // basic has no room for. The context is dropped
                              // deliberately: advanced re-derives it from the
                              // selected thread, and carrying a half-built
                              // ComposeContext across a mode switch would be a
                              // second source of truth for the same thing.
                              onCompose: { _ in setPaneMode(.advanced) })
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(AinkradSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The root fill, for the reason `RavenShell` documents: this padding
        // and the gap between panes are part of Raven's pane too, and with
        // transparency off they would stay glass while the panes went solid.
        .background(theme.background.opacity(runtime.appearanceStore.appearance.surfaceOpacity))
    }
}
