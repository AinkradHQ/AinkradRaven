import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The thread list. Search is scoped to whatever `SyncEngine` has actually
/// synced (90 days by default) — the placeholder says so plainly, and
/// `from:` matches only the sender's address, never their display name (see
/// `ThreadSearch`), so the field never implies broader or smarter coverage
/// than it has.
public struct InboxSurface: View {
    @Bindable var model: RavenViewModel

    public init(model: RavenViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSearchField(
                text: $model.searchText,
                placeholder: "Search synced mail — from:, label:, is:unread, is:starred")

            if model.visibleThreads.isEmpty {
                AinkradEmptyState(
                    icon: "tray",
                    title: model.searchText.isEmpty ? "Nothing synced yet" : "No matches",
                    message: model.searchText.isEmpty
                        ? "Connect an account in Settings to start syncing."
                        : "Nothing in the synced window matches that search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visibleThreads, id: \.id) { summary in
                            row(for: summary)
                        }
                    }
                }
            }
        }
        .padding(AinkradSpacing.md)
        .ainkradPanel()
        .onAppear { model.reload() }
    }

    private func row(for summary: ThreadSummary) -> some View {
        AinkradListRow(
            isSelected: model.selectedThread?.id == summary.id,
            onTap: { model.select(summary.id) },
            leading: {
                AinkradIconGlyph(systemName: summary.isStarred ? "star.fill" : "envelope")
            },
            title: summary.subject.isEmpty ? "(no subject)" : summary.subject,
            subtitle: subtitle(for: summary),
            trailing: {
                if summary.unreadCount > 0 {
                    AinkradBadge(text: "\(summary.unreadCount)", status: .success)
                }
            })
    }

    private func subtitle(for summary: ThreadSummary) -> String {
        let sender = summary.participants.first?.displayLabel ?? "Unknown sender"
        return summary.snippet.isEmpty ? sender : "\(sender) — \(summary.snippet)"
    }
}
