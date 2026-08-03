import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The Sending group: the undo-send hold window, and a plain statement of what
/// scheduled sends can and cannot promise.
///
/// The hold window applies identically to the human Send button and to Sage's
/// `send_draft` — see `RavenMCPOperations`'s doc comment on that tool for the
/// reasoning — so this one setting covers both, which the hint now says rather
/// than leaving it to be discovered.
struct SendingSettingsGroup: View {
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    /// Mirrors `runtime.holdWindow`. Held as text so a half-typed number does
    /// not momentarily read as a valid setting — only a parse that succeeds and
    /// is non-negative is written through.
    @State private var holdWindowText = ""

    private static let presets: [Double] = [0, 5, 10, 20, 30]

    var body: some View {
        AinkradSettingsPanel(
            title: "Sending",
            hint: "How long a sent message stays cancelable before it actually leaves. This "
                + "applies both to messages you send yourself and to ones Sage sends with "
                + "send_draft. Zero means a message goes the moment you press Send, with no "
                + "undo."
        ) {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                AinkradFormRow(title: "Undo window",
                              help: "Seconds. The composer shows a live countdown for this long.",
                              controlWidth: 260) {
                    HStack(spacing: AinkradSpacing.sm) {
                        AinkradTextField(text: $holdWindowText, placeholder: "20")
                            .frame(width: 70)
                            .onChange(of: holdWindowText) { _, newValue in
                                guard let seconds = Double(newValue), seconds >= 0 else { return }
                                runtime.holdWindow = seconds
                            }
                        // The presets exist because "20" is a number nobody has
                        // an opinion about until they see the alternatives.
                        ForEach(Self.presets, id: \.self) { preset in
                            AinkradChip(label: "\(Int(preset))s")
                                .opacity(Double(holdWindowText) == preset ? 1 : 0.55)
                                .onTapGesture { holdWindowText = String(Int(preset)) }
                        }
                    }
                }

                caption("Scheduled sends fire only while Raven is running. A message scheduled "
                        + "for 3am while your Mac is asleep sends when the app next wakes, not "
                        + "at 3am.")
            }
        }
        .onAppear { holdWindowText = String(Int(runtime.holdWindow)) }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AinkradFontResolver.font(.caption, typography: typo))
            .foregroundStyle(theme.foreground.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: AinkradSettingsPanel<EmptyView>.hintReadingWidth, alignment: .leading)
    }
}
