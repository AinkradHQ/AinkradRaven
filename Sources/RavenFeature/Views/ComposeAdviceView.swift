import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Renders `ComposeAdvice.findings(for:)` and nothing else.
///
/// The view holds NO rule. Every "is this a mistake?" decision is in
/// `ComposeAdvice`, which is why each rule has a test that fails when its check
/// is removed — a rule living inside a `body` cannot be tested and so quietly
/// stops working.
///
/// Only `.notice` findings appear here. The `.confirm` ones are the send
/// dialog's text, deliberately: showing them inline as well would say the same
/// thing twice and, worse, train the user to read compose warnings as
/// decoration before the one that matters arrives.
struct ComposeAdviceView: View {
    let findings: [ComposeFinding]
    let onApply: (ComposeCorrection) -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    private var notices: [ComposeFinding] {
        findings.filter { $0.severity == .notice }
    }

    var body: some View {
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                ForEach(notices) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: AinkradSpacing.xs) {
                        AinkradIconGlyph(systemName: "lightbulb")
                        Text(finding.message)
                            .font(AinkradFontResolver.font(.caption, typography: typo))
                            .foregroundStyle(theme.foreground.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        if let correction = finding.correction {
                            AinkradButton(title: Self.actionTitle(for: correction), style: .ghost) {
                                onApply(correction)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// The verb on the correction button. Named after what it DOES, never
    /// "Apply" or "Fix" — the whole contract of a correction here is that the
    /// user can see what pressing it will change before pressing it.
    static func actionTitle(for correction: ComposeCorrection) -> String {
        switch correction {
        case .useSubject: return "Use It"
        case .replaceRecipient(_, let with): return "Use \(with.email)"
        case .dedupeRecipients: return "Tidy Recipients"
        case .attachFiles: return "Attach…"
        }
    }
}
