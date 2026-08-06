import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The outbox entries a human has to resolve, at the TOP of Settings and styled
/// as a problem.
///
/// These used to be the last panel on the page, rendered as two lists of plain
/// rows visually identical to a signature field — which is the wrong weight for
/// the only thing in Settings that can mean a message did not go out. Two
/// distinct situations, kept distinct:
///
/// - **Needs review**: in flight when the app last quit, so nobody knows
///   whether it transmitted. `Outbox` deliberately does not guess (see its own
///   documentation); discarding drops the queued copy, which is safe only once
///   the user has checked their Sent mail.
/// - **Dead-lettered**: retried to exhaustion and definitively not sent.
///
/// The whole group renders nothing at all when both queues are empty. An
/// always-present "Outbox — None" heading trains people to ignore the place
/// where the alarming thing will eventually appear.
struct OutboxAttentionGroup: View {
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradStatusColors) private var statusColors

    /// Bumped after a discard so the snapshots are re-read.
    @State private var version = 0

    var body: some View {
        let needsReview = { _ = version; return runtime.outboxNeedsReview }()
        let deadLettered = runtime.outboxDeadLettered
        Group {
            if needsReview.isEmpty && deadLettered.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    header(count: needsReview.count + deadLettered.count)
                    if !needsReview.isEmpty {
                        section(
                            title: "Needs review",
                            note: "These were in flight when Raven last quit, so their outcome "
                                + "is unknown. Check your Sent mail before discarding — "
                                + "discarding only drops the queued copy.",
                            status: .warning,
                            entries: needsReview)
                    }
                    if !deadLettered.isEmpty {
                        section(
                            title: "Dead-lettered",
                            note: "These were retried until they gave up and were NOT sent.",
                            status: .danger,
                            entries: deadLettered)
                    }
                }
                .padding(AinkradSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChamferShape(cut: AinkradRadius.md)
                    .fill(statusColors.warning.opacity(0.10)))
                .overlay(ChamferShape(cut: AinkradRadius.md)
                    .strokeBorder(statusColors.warning.opacity(0.55), lineWidth: 1))
            }
        }
        .onAppear { runtime.refreshOutboxSnapshots() }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconGlyph(systemName: "exclamationmark.triangle", size: 22, filled: true)
            Text("Needs your attention")
                .font(AinkradFontResolver.font(.headline, weight: .medium, typography: typo))
                .foregroundStyle(theme.foreground)
            AinkradBadge(text: "\(count)", status: .warning)
        }
    }

    private func section(title: String, note: String, status: AinkradStatus,
                        entries: [OutboxEntry]) -> some View {
        AinkradSectionFrame(title: title) {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                Text(note)
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(entries) { entry in
                    AinkradListRow(
                        onTap: nil,
                        leading: { AinkradIconGlyph(systemName: glyph(entry.operation)) },
                        title: describe(entry.operation),
                        subtitle: entry.lastError ?? subtitle(for: status),
                        trailing: {
                            AinkradButton(title: "Discard", style: .danger) {
                                runtime.discardOutboxEntry(entry.id)
                                version += 1
                            }
                        })
                }
            }
        }
    }

    private func subtitle(for status: AinkradStatus) -> String {
        status == .warning ? "Outcome unknown — check before discarding." : "Not sent."
    }

    private func glyph(_ operation: OutboxEntry.Operation) -> String {
        switch operation {
        case .send: return "paperplane"
        case .labels: return "tag"
        }
    }

    private func describe(_ operation: OutboxEntry.Operation) -> String {
        switch operation {
        case .send(let message):
            return "Send: \(message.subject.isEmpty ? "(no subject)" : message.subject)"
        case .labels(let mutation):
            return "Label change on \(mutation.threadIDs.count) thread"
                + (mutation.threadIDs.count == 1 ? "" : "s")
        }
    }
}
