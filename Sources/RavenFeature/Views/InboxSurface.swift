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
/// Layout: search field, then ONE toolbar carrying the row actions
/// (archive/star/unread/trash) and the account filter, then the rows.
///
/// The actions used to live on every row, four icon buttons deep in each
/// trailing edge — sixteen buttons visible in a four-row window, all of them
/// competing with the subject and snippet that are the row's actual content,
/// and none of them reachable without hunting for the right row's copy. There
/// is now one set, in the toolbar, acting on whatever is active (the
/// multi-selection, else the focused row) — the same `activeThreadIDs` the
/// `e`/`u` keyboard shortcuts have always used, so mouse and keyboard cannot
/// disagree about the target. Rows keep their hover/selection affordance and
/// their right-click menu; what they lost is the clutter.
///
/// `j`/`k`/`e`/`u`/`/` navigation and shift/cmd multi-select all still route
/// through `RavenViewModel` — see that type for why the mutation itself lives
/// there rather than here (it's shared with `RavenMCPOperations` via
/// `ThreadAction`, so Sage and the human can never disagree about what
/// "archive" means).
public struct InboxSurface: View {
    @Bindable var model: RavenViewModel
    let runtime: RavenRuntime

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

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

            actionToolbar

            content
            archiveSearchSection
        }
        .padding(AinkradSpacing.md)
        .ravenSurface(runtime.appearanceStore.appearance)
        .focusable()
        .focused($listFocused)
        // `.focusable()` is here for `onKeyPress` (j/k/e/u//), not for the ring
        // AppKit draws as a side effect of it. `ravenFocusRing` disables that
        // system ring and substitutes a restrained theme-coloured one that is
        // also suppressed while a modal covers this pane — see `RavenFocusRing`.
        .ravenFocusRing(isFocused: listFocused)
        .onKeyPress { press in handle(press) }
        .onAppear {
            model.reload()
            listFocused = true
        }
    }

    // MARK: Toolbar

    /// The one action bar for the pane. In its normal state it acts on the
    /// focused row and carries the account filter; with rows multi-selected it
    /// becomes a bulk bar that says how many and drops the filter (re-scoping
    /// the list mid-selection would silently change what "apply to all" means).
    ///
    /// Both states call the SAME `model.…Active()` methods, which target
    /// `activeThreadIDs`. There is no separate bulk code path, so a bulk
    /// archive and a single archive cannot drift apart.
    @ViewBuilder
    private var actionToolbar: some View {
        let selectionCount = model.multiSelection.count
        HStack(spacing: AinkradSpacing.xs) {
            if selectionCount > 0 {
                AinkradBadge(text: "\(selectionCount) selected", status: .success)
                AinkradIconButton(systemName: "xmark.circle", size: 24, tooltip: "Clear selection") {
                    model.clearMultiSelection()
                }
                Spacer(minLength: AinkradSpacing.xs)
            }

            if actionsEnabled {
                AinkradIconButton(systemName: "archivebox", size: 26,
                                  tooltip: archiveTooltip(selectionCount)) {
                    model.archiveActive()
                }
                AinkradIconButton(systemName: "star", size: 26,
                                  tooltip: starTooltip(selectionCount)) {
                    model.starActive(!allActiveStarred)
                }
                AinkradIconButton(systemName: "envelope.badge", size: 26,
                                  tooltip: unreadTooltip(selectionCount)) {
                    model.toggleUnreadActive()
                }
                AinkradIconButton(systemName: "trash", size: 26,
                                  tooltip: trashTooltip(selectionCount)) {
                    model.trashActive()
                }
            }

            if selectionCount == 0 {
                Spacer(minLength: AinkradSpacing.xs)
                if runtime.accounts.count > 1 { accountFilter }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AinkradSpacing.xs)
        .padding(.vertical, AinkradSpacing.xs)
        .background(ChamferShape(cut: AinkradRadius.sm)
            .fill(theme.surfaceElevated.opacity(selectionCount > 0 ? 0.55 : 0.28)))
    }

    /// Whether the mutating toolbar controls render at all.
    ///
    /// Two independent reasons they do not, both previously enforced only on
    /// the per-row buttons:
    ///
    /// - Nothing is active, so every button would be a no-op.
    /// - Every active thread belongs to a read-only account (an Apple Mail
    ///   import), which has no transport to carry a mutation. Offering a button
    ///   that would only be refused deeper in the stack is worse than not
    ///   showing it. A read thread stays fully readable either way.
    private var actionsEnabled: Bool {
        let ids = model.activeThreadIDs
        guard !ids.isEmpty else { return false }
        return activeSummaries.contains { !runtime.isReadOnly(accountID: $0.accountID) }
    }

    /// The active ids resolved back to summaries. Archive-search hits are part
    /// of the pool: clicking one focuses a thread that is NOT in the windowed
    /// list, and resolving against `visibleThreads` alone would leave the
    /// toolbar inert for exactly the row the user just clicked — which is what
    /// the per-row buttons used to cover.
    private var activeSummaries: [ThreadSummary] {
        let ids = Set(model.activeThreadIDs)
        guard !ids.isEmpty else { return [] }
        var pool = model.visibleThreads
        if case .results(let hits) = runtime.archiveSearchState { pool += hits }
        return pool.filter { ids.contains($0.id) }
    }

    /// Star is a toggle, so the button has to know which way it would flip: if
    /// everything active is already starred, pressing it unstars. Matches the
    /// per-row button it replaces.
    private var allActiveStarred: Bool {
        let summaries = activeSummaries
        return !summaries.isEmpty && summaries.allSatisfy(\.isStarred)
    }

    private func suffix(_ count: Int) -> String { count > 1 ? " \(count) threads" : "" }
    private func archiveTooltip(_ count: Int) -> String { "Archive\(suffix(count)) (e)" }
    private func starTooltip(_ count: Int) -> String {
        (allActiveStarred ? "Unstar" : "Star") + suffix(count)
    }
    private func unreadTooltip(_ count: Int) -> String { "Toggle read/unread\(suffix(count)) (u)" }
    private func trashTooltip(_ count: Int) -> String { "Trash\(suffix(count))" }

    /// The per-account filter that drives `model.accountID` — and, through it,
    /// `RavenViewModel.reload()`'s `scopedAccountIDs`, which is what actually
    /// narrows `UnifiedInbox.inbox(store:accountIDs:months:)`. There is
    /// deliberately no client-side re-filtering of an already-merged list
    /// here: picking an account changes what gets READ, not what gets hidden
    /// after the fact. Only shown once there is something to disambiguate —
    /// with a single account this control would be pure noise.
    private var accountFilter: some View {
        AinkradSegmentedPicker(
            items: [nil] + runtime.accounts.map { Optional($0.id) },
            selection: $model.accountID,
            label: { accountID in
                guard let accountID else { return "All" }
                let address = runtime.accounts.first { $0.id == accountID }?.address ?? accountID
                return String(address.split(separator: "@").first ?? Substring(address))
            })
            .onChange(of: model.accountID) { _, _ in model.reload() }
    }

    // MARK: Content

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
            // The kit's own loading state, not a bare ProgressView + Text.
            AinkradLoadingState(label: "Searching all mail…")
                .frame(height: 72)
        case .failed(let message):
            AinkradErrorState(message: "Search all mail failed: \(message)")
                .frame(height: 96)
        case .results(let hits):
            AinkradSectionFrame(title: hits.isEmpty
                                ? "All mail: no matches"
                                : "All mail (\(hits.count))") {
                if hits.isEmpty {
                    Text("Gmail's full-archive search found nothing for this query.")
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                        .foregroundStyle(theme.foreground.opacity(0.6))
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(hits, id: \.id) { summary in
                            row(for: summary)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
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
            .frame(maxHeight: .infinity)
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
            // The "Search all mail" escalation is `AinkradEmptyState`'s own
            // call-to-action now rather than a bare `Button` bolted underneath
            // it. Still a deliberate, explicit act — never automatic, and
            // never fired per keystroke — per `RavenRuntime.searchArchive`.
            AinkradEmptyState(
                icon: "magnifyingglass",
                title: "No matches",
                message: "Nothing in the synced window matches that search.",
                actionTitle: "Search all mail",
                action: { Task { await runtime.searchArchive(query: model.searchText) } })
        } else if model.summaries.isEmpty, let lastSyncError = model.lastSyncError {
            AinkradErrorState(message: "Sync failed: \(lastSyncError)")
        } else {
            AinkradEmptyState(
                icon: "tray",
                title: "Nothing synced yet",
                message: "Connect an account in Settings to start syncing.")
        }
    }

    // MARK: Rows

    /// One thread row — see `InboxRow`, which owns the layout and the line
    /// limits that keep the rail scannable. This supplies only the facts the
    /// row cannot know for itself (selection, which badges apply) and the
    /// interaction, which stays here because both route into `model`.
    private func row(for summary: ThreadSummary) -> some View {
        let isFocused = model.focusedThreadID == summary.id
        let isMultiSelected = model.multiSelection.contains(summary.id)
        return InboxRow(
            summary: summary,
            isSelected: model.selectedThread?.id == summary.id || isFocused || isMultiSelected,
            isUnread: summary.unreadCount > 0,
            accountLabel: accountBadgeLabel(for: summary),
            rowError: model.rowErrors[summary.id],
            onTap: {
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                model.clickRow(summary.id,
                               shift: modifiers.contains(.shift),
                               command: modifiers.contains(.command))
            })
            .ainkradContextMenu(contextMenuItems(for: summary))
    }

    /// The right-click menu is where a SINGLE row's own actions still live —
    /// the toolbar acts on the active selection, and there has to be a way to
    /// act on the row under the cursor without first selecting it.
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
