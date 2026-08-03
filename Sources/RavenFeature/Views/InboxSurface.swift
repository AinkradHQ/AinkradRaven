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
    let runtime: RavenRuntime

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    public init(model: RavenViewModel, runtime: RavenRuntime) {
        self.model = model
        self.runtime = runtime
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSearchField(
                text: $model.searchText,
                placeholder: "Search synced mail — from:, label:, is:unread, is:starred",
                onSubmit: { Task { await runtime.searchArchive(query: model.searchText) } },
                focus: $searchFocused)
                .onChange(of: model.searchText) {
                    if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        runtime.clearArchiveSearch()
                    }
                }

            if runtime.accounts.count > 1 {
                accountFilter
            }

            if !model.multiSelection.isEmpty {
                selectionBar
            }

            content
            archiveSearchSection
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

    /// The per-account filter that drives `model.accountID` — and, through it,
    /// `RavenViewModel.reload()`'s `scopedAccountIDs`, which is what actually
    /// narrows `UnifiedInbox.inbox(store:accountIDs:months:)`. There is
    /// deliberately no client-side re-filtering of an already-merged list
    /// here: picking an account changes what gets READ, not what gets hidden
    /// after the fact. Only shown once there is something to disambiguate —
    /// with a single account this row would be pure noise.
    private var accountFilter: some View {
        AinkradSegmentedPicker(
            items: [nil] + runtime.accounts.map { Optional($0.id) },
            selection: $model.accountID,
            label: { accountID in
                guard let accountID else { return "All" }
                return runtime.accounts.first { $0.id == accountID }?.address ?? accountID
            })
            .onChange(of: model.accountID) { _, _ in model.reload() }
    }

    /// A "results from all mail" list, kept visibly SEPARATE from the Inbox's
    /// windowed `visibleThreads` above — see `RavenRuntime.searchArchive`'s
    /// documentation for why blending an archive hit into the windowed list
    /// would misrepresent what that list means. Only shown once a search has
    /// actually been submitted (`archiveSearchState != .idle`).
    @ViewBuilder
    private var archiveSearchSection: some View {
        switch runtime.archiveSearchState {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: AinkradSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Searching all mail…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, AinkradSpacing.sm)
        case .failed(let message):
            AinkradErrorState(message: "Search all mail failed: \(message)")
                .padding(.top, AinkradSpacing.sm)
        case .results(let hits):
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                Divider()
                Text(hits.isEmpty ? "All mail: no matches" : "Results from all mail (\(hits.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if hits.isEmpty {
                    Text("Gmail's full-archive search found nothing for this query.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hits, id: \.id) { summary in
                        row(for: summary)
                    }
                }
            }
            .padding(.top, AinkradSpacing.sm)
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
            VStack(spacing: AinkradSpacing.sm) {
                AinkradEmptyState(
                    icon: "tray",
                    title: "No matches",
                    message: "Nothing in the synced window matches that search.")
                // Deliberate, explicit act — never automatic — per
                // `RavenRuntime.searchArchive`'s documentation. Offered here
                // because local results are empty, not fired on every
                // keystroke.
                Button("Search all mail") {
                    Task { await runtime.searchArchive(query: model.searchText) }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
            }
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
                    if let accountLabel = accountBadgeLabel(for: summary) {
                        AinkradBadge(text: accountLabel, status: .neutral)
                    }
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

    /// Mutation affordances (star/read/archive/trash) never render for a
    /// thread whose account is read-only (an Apple Mail import): the account
    /// has no transport to carry any of them, and offering a button that
    /// would only be refused deeper in the stack is worse than not showing
    /// it at all. A read thread is still fully readable — only the mutating
    /// actions disappear.
    private func rowActions(for summary: ThreadSummary) -> some View {
        HStack(spacing: 2) {
            if !runtime.isReadOnly(accountID: summary.accountID) {
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
    }

    private func contextMenuItems(for summary: ThreadSummary) -> [AinkradMenuItem] {
        guard !runtime.isReadOnly(accountID: summary.accountID) else { return [] }
        return [
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

    /// The account attribution badge text for a row, or `nil` when there is
    /// nothing to disambiguate: with a single connected account, or with the
    /// Inbox already filtered to exactly one, every row obviously belongs to
    /// the same mailbox and a badge would be noise rather than information.
    /// Present but unobtrusive is the point with several accounts unfiltered
    /// — a short local part, not the full address, keeps the row's real
    /// content (subject/snippet) the visual lead.
    private func accountBadgeLabel(for summary: ThreadSummary) -> String? {
        guard runtime.accounts.count > 1, model.accountID == nil else { return nil }
        let address = model.address(ofAccount: summary.accountID) ?? summary.accountID
        return String(address.split(separator: "@").first ?? Substring(address))
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
