import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The Privacy group: what remote-image blocking actually guarantees, and the
/// senders the user has chosen to exempt from it.
///
/// New in this pass, and the reason it is: the allow-list was write-only. A user
/// could press "Load images" on a message and afterwards had no way to see who
/// they had trusted, let alone undo it. `RemoteImageAllowList.allowedSenders` /
/// `.revoke` (via `RavenRuntime`) are the reads and the one mutation that makes
/// this listable and reversible; nothing about the blocked-by-default behaviour
/// changed.
struct PrivacySettingsGroup: View {
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    @State private var isExpanded = false
    /// Bumped after a revoke so `runtime.allowedImageSenders` — a plain read
    /// through the document store, not `@Observable` storage — is re-read.
    @State private var version = 0

    var body: some View {
        AinkradSettingsPanel(
            title: "Privacy",
            hint: "Remote images are blocked in every message by default, so a tracking pixel "
                + "cannot fire just because you opened your mail. Blocking is enforced by a "
                + "Content Security Policy on the message view, not by rewriting the markup, "
                + "and JavaScript is off in both states — allowing a sender's images is never "
                + "allowing their code."
        ) {
            let senders = { _ = version; return runtime.allowedImageSenders }()
            AinkradDisclosureGroup(
                title: "Senders allowed to load images",
                isExpanded: $isExpanded,
                hitCount: senders.count
            ) {
                if senders.isEmpty {
                    caption("Nobody yet. Pressing \"Load images\" on a message adds that "
                            + "sender here, and images from them load automatically from then on.")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(senders, id: \.self) { sender in
                            AinkradListRow(
                                onTap: nil,
                                leading: { AinkradIconGlyph(systemName: "photo") },
                                title: sender,
                                subtitle: "Images load automatically",
                                trailing: {
                                    AinkradButton(title: "Revoke", style: .ghost) {
                                        runtime.revokeImages(for: sender)
                                        version += 1
                                    }
                                })
                        }
                    }
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AinkradFontResolver.font(.caption, typography: typo))
            .foregroundStyle(theme.foreground.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: AinkradSettingsPanel<EmptyView>.hintReadingWidth, alignment: .leading)
    }
}
