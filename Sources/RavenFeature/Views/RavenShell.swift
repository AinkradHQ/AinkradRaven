import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The app's root view: a Mail/Compose switcher over the inbox+thread split
/// and the composer, all driven by the one `RavenRuntime` for this host.
public struct RavenShell: View {
    let runtime: RavenRuntime

    private enum Surface: Hashable { case mail, compose }
    @State private var surface: Surface = .mail

    public init(runtime: RavenRuntime) { self.runtime = runtime }

    public var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack {
                AinkradSegmentedPicker(items: [Surface.mail, .compose], selection: $surface) { s in
                    switch s {
                    case .mail: return "Mail"
                    case .compose: return "Compose"
                    }
                }
                Spacer()
            }

            switch surface {
            case .mail:
                HStack(spacing: AinkradSpacing.sm) {
                    InboxSurface(model: runtime.model)
                        .frame(width: 340)
                    ThreadSurface(model: runtime.model, loadBody: runtime.loadBody)
                        .frame(maxWidth: .infinity)
                }
            case .compose:
                ComposeSurface(runtime: runtime)
            }
        }
        .padding(AinkradSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
