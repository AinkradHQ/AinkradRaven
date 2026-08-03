import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Renders `model.selectedThread`: a header naming the conversation and who is
/// in it, one toolbar of actions beneath it, then the messages.
///
/// Bodies default to the sanitized plain text (`MessageBody.plainText`) — per
/// `BodySanitizer`'s own contract, that text must never be re-rendered as HTML
/// or Markdown, only as plain text — and "Show original" opens the raw HTML in
/// a `WKWebView` (see `ThreadRawHTMLView.swift`).
///
/// Reply/Reply-all/Forward are NOT composed here any more. They hand a
/// `ComposeContext` up to `RavenShell`, which presents the one `ComposeSurface`
/// overlay. The inline panel this replaces was a second composer with its own
/// fields, its own validation and its own send call — a draft typed into it
/// vanished the moment the thread selection changed, because it lived in the
/// panel's `@State` and nothing else. The send path itself is unchanged:
/// `RavenRuntime.sendThreadReply`, the same `SendAttempt`
/// queue→drain→classify every other send in this app goes through.
public struct ThreadSurface: View {
    @Bindable var model: RavenViewModel
    let runtime: RavenRuntime
    /// How this pane asks the shell to open the compose overlay. A closure
    /// rather than shared state: the thread pane's job ends at "the user wants
    /// to reply to this", and it must not also own the composer's lifetime.
    let onCompose: (ComposeContext) -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    /// The message whose raw HTML the toolbar's "Show original" is showing.
    @State private var originalMessage: MailMessage?
    @State private var showingOriginal = false
    @State private var showingOverflow = false

    public init(model: RavenViewModel, runtime: RavenRuntime,
                onCompose: @escaping (ComposeContext) -> Void) {
        self.model = model
        self.runtime = runtime
        self.onCompose = onCompose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thread = model.selectedThread {
                header(thread)
                toolbar(thread)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                        ForEach(thread.messages, id: \.id) { message in
                            MessageRow(message: message, runtime: runtime)
                        }
                    }
                    .padding(AinkradSpacing.md)
                }
            } else {
                AinkradEmptyState(icon: "envelope.open",
                                  title: "No thread selected",
                                  message: "Pick a conversation from the inbox to read it.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ainkradPanel()
        .ainkradModal(isPresented: $showingOriginal, contentWidth: 640) {
            if let message = originalMessage {
                ThreadOriginalLoader(message: message, runtime: runtime,
                                    onClose: { showingOriginal = false })
            }
        }
    }

    // MARK: Header

    /// Subject plus who is actually in the conversation — the two facts that
    /// tell a user what they are reading. The previous header said only the
    /// subject and a message count, so a thread with six participants looked
    /// identical to a one-to-one.
    private func header(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                .font(AinkradFontResolver.font(.title, weight: .semibold, typography: typo))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AinkradSpacing.xs) {
                Text(participantLabel(thread))
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.6))
                    .lineLimit(2)
                Spacer(minLength: AinkradSpacing.sm)
                AinkradBadge(text: "\(thread.messages.count) message"
                             + (thread.messages.count == 1 ? "" : "s"), status: .neutral)
                if runtime.isReadOnly(accountID: thread.accountID) {
                    // Says why the mutating half of the toolbar is missing,
                    // rather than leaving its absence to be guessed at.
                    AinkradBadge(text: "Read-only", status: .warning)
                        .ainkradTooltip("This account was imported from Apple Mail. It has no "
                                        + "transport, so it cannot send or change labels.")
                }
            }
        }
        .padding(.horizontal, AinkradSpacing.md)
        .padding(.top, AinkradSpacing.md)
    }

    /// Every distinct participant across the thread, senders first, de-duped by
    /// address so a ten-message exchange between two people reads as two names
    /// rather than ten.
    private func participantLabel(_ thread: MailThread) -> String {
        var seen: Set<String> = []
        var labels: [String] = []
        for message in thread.messages {
            for address in [message.from].compactMap({ $0 }) + message.to + message.cc {
                let key = address.email.lowercased()
                guard seen.insert(key).inserted else { continue }
                labels.append(address.displayLabel)
            }
        }
        return labels.isEmpty ? "No participants" : labels.joined(separator: ", ")
    }

    // MARK: Toolbar

    /// One row of actions for the thread on screen. Composing actions come
    /// first (they are what a reader most often wants), then the state
    /// mutations, then "Show original", then the overflow menu.
    ///
    /// Read-only accounts (Apple Mail imports) render none of the mutating or
    /// sending controls: that account has no transport to carry them, and a
    /// button that can only be refused deeper in the stack is worse than no
    /// button. Reading is unaffected.
    private func toolbar(_ thread: MailThread) -> some View {
        let canMutate = !runtime.isReadOnly(accountID: thread.accountID)
        return HStack(spacing: AinkradSpacing.xs) {
            if canMutate {
                AinkradButton(title: "Reply", style: .primary,
                              icon: "arrowshape.turn.up.left") { compose(.reply, thread) }
                AinkradButton(title: "Reply All", style: .secondary,
                              icon: "arrowshape.turn.up.left.2") { compose(.replyAll, thread) }
                AinkradButton(title: "Forward", style: .secondary,
                              icon: "arrowshape.turn.up.right") { compose(.forward, thread) }

                Divider().frame(height: 18).padding(.horizontal, AinkradSpacing.xs)

                AinkradIconButton(systemName: "archivebox", size: 26, tooltip: "Archive (e)") {
                    model.archive([thread.id])
                }
                AinkradIconButton(systemName: isStarred(thread) ? "star.fill" : "star", size: 26,
                                  tooltip: isStarred(thread) ? "Unstar" : "Star") {
                    model.star([thread.id], starred: !isStarred(thread))
                }
                AinkradIconButton(systemName: "trash", size: 26, tooltip: "Trash") {
                    model.trash([thread.id])
                }
            }

            Spacer(minLength: AinkradSpacing.xs)

            AinkradButton(title: "Show original", style: .ghost, icon: "safari") {
                originalMessage = thread.messages.last
                showingOriginal = true
            }
            .disabled(thread.messages.isEmpty)

            AinkradIconButton(systemName: "ellipsis", size: 26, tooltip: "More actions") {
                showingOverflow.toggle()
            }
            // The ⋯ menu and the pane's own right-click menu are built from the
            // SAME `[AinkradMenuItem]` array, so there is one declaration of
            // what "more actions" means rather than two that can drift.
            .ainkradFloatingPanel(isPresented: $showingOverflow, maxHeight: 260) {
                OverflowMenu(items: overflowItems(thread),
                            onSelect: { showingOverflow = false })
            }
        }
        .padding(.horizontal, AinkradSpacing.md)
        .padding(.vertical, AinkradSpacing.sm)
        .ainkradContextMenu(overflowItems(thread))
    }

    /// A thread counts as starred when any message in it is — the same rule
    /// `ThreadSummary.isStarred` carries into the inbox row, so the star in the
    /// list and the star in this toolbar always agree.
    private func isStarred(_ thread: MailThread) -> Bool {
        thread.messages.contains(where: \.isStarred)
    }

    // The toolbar's "Show original" targets the NEWEST message and is always
    // offered, rather than being gated on that message actually having HTML.
    //
    // Checked for a cheaper signal on the message metadata first: there is none.
    // `MailMessage` records `hasAttachments` and `attachments` but nothing about
    // which body parts a message carried; whether HTML exists is known only from
    // `MessageBody.html`, which requires `store.body(messageID:)` — a document
    // read per message on every render pass of this pane (i.e. per keystroke in
    // the search field next to it) purely to hide a button. So it stays
    // ungated, and `ThreadOriginalLoader` says "no original to show" for a
    // plain-text message instead, costing one read only when asked.
    // Older messages in a long thread keep their own copy of the button (see
    // `MessageRow`), which is already loading its body anyway.

    private func overflowItems(_ thread: MailThread) -> [AinkradMenuItem] {
        var items: [AinkradMenuItem] = []
        if !runtime.isReadOnly(accountID: thread.accountID) {
            items.append(AinkradMenuItem(title: "Mark unread", systemName: "envelope.badge",
                                         shortcut: "U") {
                model.setRead([thread.id], read: false)
            })
            items.append(AinkradMenuItem(title: "Mark read", systemName: "envelope.open") {
                model.setRead([thread.id], read: true)
            })
        }
        items.append(AinkradMenuItem(title: "Close thread", systemName: "xmark") {
            model.clearSelection()
        })
        return items
    }

    /// Builds the `ComposeContext` for a reply/forward and hands it up. The
    /// routing facts (which account, which message to thread onto) are captured
    /// HERE, from the thread actually on screen, and travel with the context —
    /// the composer never re-guesses them. See `ComposeContext.stamp`.
    private func compose(_ mode: ReplyComposer.Mode, _ thread: MailThread) {
        onCompose(.reply(mode: mode, thread: ComposeThreadReference(
            threadID: thread.id,
            accountID: thread.accountID,
            lastMessageRFC822ID: thread.messages.last?.rfc822MessageID)))
    }
}

/// The ⋯ overflow list. `AinkradMenuItem` is the kit's menu-item model and
/// `AinkradListRow` its row; the kit has no button-anchored menu component, so
/// this composes those two inside `.ainkradFloatingPanel` rather than adding a
/// bespoke menu look.
private struct OverflowMenu: View {
    let items: [AinkradMenuItem]
    let onSelect: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                AinkradListRow(
                    onTap: { item.action(); onSelect() },
                    leading: {
                        if let systemName = item.systemName {
                            AinkradIconGlyph(systemName: systemName)
                        }
                    },
                    title: item.title,
                    trailing: {
                        if let shortcut = item.shortcut { AinkradKbd(shortcut) }
                    })
                    .foregroundStyle(item.isDestructive ? statusColors.danger : theme.foreground)
            }
        }
        .padding(AinkradSpacing.xs)
        .frame(minWidth: 200)
    }
}

/// Loads one message's body (it may not be in the store yet) and then shows its
/// raw HTML. Kept separate from `RawHTMLSheet` so that view keeps its single
/// job — rendering HTML under a CSP — and never becomes a loader too.
private struct ThreadOriginalLoader: View {
    let message: MailMessage
    let runtime: RavenRuntime
    let onClose: () -> Void

    @State private var body_: MessageBody?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let html = body_?.html {
                RawHTMLSheet(html: html, sender: message.from?.email, runtime: runtime,
                            onClose: onClose)
            } else if isLoading {
                AinkradLoadingState(label: "Loading original…")
                    .frame(height: 200)
            } else {
                AinkradEmptyState(icon: "safari", title: "No original to show",
                                  message: "This message was sent as plain text only.")
                    .frame(height: 200)
            }
        }
        .task(id: message.id) {
            body_ = await runtime.loadBody(for: message)
            isLoading = false
        }
    }
}
