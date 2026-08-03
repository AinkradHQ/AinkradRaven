import SwiftUI
import AppKit
import AinkradAppKit
import AinkradAppKitUI

/// The thread list. Search is scoped to whatever `SyncEngine` has actually
/// synced (90 days by default) — the placeholder says so plainly, and
/// `from:` matches only the sender's address, never their display name (see
/// `ThreadSearch`), so the field never implies broader or smarter coverage
/// than it has.
///
/// Per-row actions (archive/star/read/trash), `j`/`k`/`e`/`u`/`/` keyboard
/// navigation, and shift/cmd multi-select with bulk actions all route
/// through `RavenViewModel` — see that type for why the mutation itself
/// lives there rather than here (it's shared with `RavenMCPOperations` via
/// `ThreadAction`, so Sage and the human can never disagree about what
/// "archive" means).
public struct InboxSurface: View {
    @Bindable var model: RavenViewModel

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    public init(model: RavenViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSearchField(
                text: $model.searchText,
                placeholder: "Search synced mail — from:, label:, is:unread, is:starred",
                focus: $searchFocused)

            if !model.multiSelection.isEmpty {
                selectionBar
            }

            content
        }
        .padding(AinkradSpacing.md)
        .ainkradPanel()
        .focusable()
        .focused($listFocused)
        .onKeyPress { press in handle(press) }
        .onAppear {
            model.reload()
            listFocused = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.visibleThreads.isEmpty {
            emptyState
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

    /// Three genuinely different empty states — never one message doing
    /// triple duty. A search with no hits is not the same situation as an
    /// account that hasn't synced anything yet, and neither is the same as a
    /// sync that actively failed; conflating them either hides a real error
    /// or scares a user who simply hasn't connected an account.
    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            AinkradEmptyState(
                icon: "tray",
                title: "No matches",
                message: "Nothing in the synced window matches that search.")
        } else if model.summaries.isEmpty, let lastSyncError = model.lastSyncError {
            AinkradErrorState(message: "Sync failed: \(lastSyncError)")
        } else {
            AinkradEmptyState(
                icon: "tray",
                title: "Nothing synced yet",
                message: "Connect an account in Settings to start syncing.")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: AinkradSpacing.sm) {
            Text("\(model.multiSelection.count) selected")
                .font(.caption.weight(.semibold))
            Button("Clear") { model.clearMultiSelection() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            AinkradIconButton(systemName: "archivebox", tooltip: "Archive selection") {
                model.archiveActive()
            }
            AinkradIconButton(systemName: "star", tooltip: "Star selection") {
                model.starActive(true)
            }
            AinkradIconButton(systemName: "envelope.badge", tooltip: "Toggle unread") {
                model.toggleUnreadActive()
            }
            AinkradIconButton(systemName: "trash", tooltip: "Trash selection") {
                model.trashActive()
            }
        }
    }

    private func row(for summary: ThreadSummary) -> some View {
        let isFocused = model.focusedThreadID == summary.id
        let isMultiSelected = model.multiSelection.contains(summary.id)
        return AinkradListRow(
            isSelected: model.selectedThread?.id == summary.id || isFocused || isMultiSelected,
            onTap: nil,
            leading: {
                AinkradIconGlyph(systemName: summary.isStarred ? "star.fill" : "envelope")
            },
            title: summary.subject.isEmpty ? "(no subject)" : summary.subject,
            subtitle: subtitle(for: summary),
            trailing: {
                HStack(spacing: AinkradSpacing.xs) {
                    if let error = model.rowErrors[summary.id] {
                        AinkradBadge(text: "!", status: .danger).ainkradTooltip(error)
                    }
                    if summary.unreadCount > 0 {
                        AinkradBadge(text: "\(summary.unreadCount)", status: .success)
                    }
                    rowActions(for: summary)
                }
            })
            .contentShape(Rectangle())
            .onTapGesture {
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                model.clickRow(summary.id,
                               shift: modifiers.contains(.shift),
                               command: modifiers.contains(.command))
            }
            .ainkradContextMenu(contextMenuItems(for: summary))
    }

    private func rowActions(for summary: ThreadSummary) -> some View {
        HStack(spacing: 2) {
            AinkradIconButton(systemName: summary.isStarred ? "star.fill" : "star",
                              size: 22, tooltip: summary.isStarred ? "Unstar" : "Star") {
                model.star([summary.id], starred: !summary.isStarred)
            }
            AinkradIconButton(systemName: summary.unreadCount > 0 ? "envelope.open" : "envelope.badge",
                              size: 22,
                              tooltip: summary.unreadCount > 0 ? "Mark read" : "Mark unread") {
                model.setRead([summary.id], read: summary.unreadCount == 0)
            }
            AinkradIconButton(systemName: "archivebox", size: 22, tooltip: "Archive") {
                model.archive([summary.id])
            }
            AinkradIconButton(systemName: "trash", size: 22, tooltip: "Trash") {
                model.trash([summary.id])
            }
        }
    }

    private func contextMenuItems(for summary: ThreadSummary) -> [AinkradMenuItem] {
        [
            AinkradMenuItem(title: summary.isStarred ? "Unstar" : "Star", systemName: "star") {
                model.star([summary.id], starred: !summary.isStarred)
            },
            AinkradMenuItem(title: summary.unreadCount > 0 ? "Mark read" : "Mark unread",
                            systemName: "envelope.badge", shortcut: "U") {
                model.setRead([summary.id], read: summary.unreadCount == 0)
            },
            AinkradMenuItem(title: "Archive", systemName: "archivebox", shortcut: "E") {
                model.archive([summary.id])
            },
            AinkradMenuItem(title: "Trash", systemName: "trash", isDestructive: true) {
                model.trash([summary.id])
            }
        ]
    }

    private func subtitle(for summary: ThreadSummary) -> String {
        let sender = summary.participants.first?.displayLabel ?? "Unknown sender"
        return summary.snippet.isEmpty ? sender : "\(sender) — \(summary.snippet)"
    }

    /// `j`/`k` move focus, `e` archives, `u` toggles read on whatever is
    /// currently active (multi-selection, else the focused row), and `/`
    /// hands focus to the search field.
    ///
    /// Two guards, both of which were previously left to luck:
    ///
    /// - **Unmodified keys only.** `press.modifiers` was ignored, so ⌘E, ⌘U,
    ///   ⌘J and ⌘K all fired these actions and could collide with the host
    ///   app's own shortcuts. A bare `e` is the shortcut; `⌘E` is somebody
    ///   else's.
    /// - **Not while searching.** Relying on `AinkradSearchField`'s `TextField`
    ///   to consume character input first is incidental, not guaranteed — a
    ///   focus change or a future field could hand the key here and archive a
    ///   thread because the user typed "e" into a search box. `searchFocused`
    ///   is checked explicitly instead.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !searchFocused else { return .ignored }
        switch press.characters {
        case "j": model.moveFocus(by: 1); return .handled
        case "k": model.moveFocus(by: -1); return .handled
        case "e": model.archiveActive(); return .handled
        case "u": model.toggleUnreadActive(); return .handled
        case "/": searchFocused = true; return .handled
        default: return .ignored
        }
    }
}
