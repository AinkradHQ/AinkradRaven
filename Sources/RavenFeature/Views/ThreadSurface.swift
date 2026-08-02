import SwiftUI
import WebKit
import AinkradAppKit
import AinkradAppKitUI

/// Renders `model.selectedThread`. Defaults to the sanitized plain text
/// (`MessageBody.plainText`) — per `BodySanitizer`'s own contract, that text
/// must never be re-rendered as HTML or Markdown, only as plain text — and
/// offers "Show original" to open the raw HTML in a `WKWebView`.
public struct ThreadSurface: View {
    @Bindable var model: RavenViewModel
    /// Fetches (and, on a miss, sanitizes) a body off the main actor — see
    /// `RavenRuntime.loadBody`. Injected rather than handing this view the
    /// whole runtime, so it depends on exactly the one capability it needs.
    let loadBody: (MailMessage) async -> MessageBody?

    public init(model: RavenViewModel, loadBody: @escaping (MailMessage) async -> MessageBody?) {
        self.model = model
        self.loadBody = loadBody
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thread = model.selectedThread {
                header(thread)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                        ForEach(thread.messages, id: \.id) { message in
                            MessageRow(message: message, loadBody: loadBody)
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
    }

    private func header(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                .font(.title3.weight(.semibold))
            Text("\(thread.messages.count) message(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(AinkradSpacing.md)
    }
}

/// One message: sender line, the visible (non-quoted) body, a disclosure for
/// the quoted trailer `QuoteTrimmer` split off, and "Show original".
private struct MessageRow: View {
    let message: MailMessage
    let loadBody: (MailMessage) async -> MessageBody?

    @State private var loadedBody: MessageBody?
    @State private var isLoading = false
    @State private var quotedExpanded = false
    @State private var showingOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack {
                Text(message.from?.displayLabel ?? "Unknown sender")
                    .font(.body.weight(.medium))
                Spacer()
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(AinkradSpacing.md)
        .background(ChamferShape(cut: 8).fill(Color.primary.opacity(0.03)))
        .task(id: message.id) {
            guard loadedBody == nil else { return }
            isLoading = true
            loadedBody = await loadBody(message)
            isLoading = false
        }
        .sheet(isPresented: $showingOriginal) {
            if let html = loadedBody?.html {
                RawHTMLSheet(html: html, onClose: { showingOriginal = false })
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isLoading && loadedBody == nil {
            AinkradLoadingState(label: "Loading message…")
        } else if let body = loadedBody {
            let split = QuoteTrimmer.split(body.plainText)
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                Text(split.visible)
                    .font(.body)
                    .textSelection(.enabled)

                if let quoted = split.quoted {
                    AinkradDisclosureGroup(title: "Show quoted text", isExpanded: $quotedExpanded) {
                        Text(quoted)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if body.html != nil {
                    AinkradButton(title: "Show original", style: .secondary, icon: "safari") {
                        showingOriginal = true
                    }
                }
            }
        } else {
            Text("(body not synced)")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// The raw-HTML "Show original" view. Remote images are stripped out of the
/// markup before it is loaded, so nothing phones home to a tracking pixel
/// merely by opening this sheet; "Load images" re-loads the untouched HTML
/// for this viewing only.
///
/// KNOWN GAP (see task report): the opt-in is per-sheet-open, not persisted
/// per sender — closing and reopening the same message blocks images again.
/// A durable per-sender allow-list is out of scope for this task.
private struct RawHTMLSheet: View {
    let html: String
    let onClose: () -> Void
    @State private var imagesAllowed = false

    private var remoteImageCount: Int { BodySanitizer.remoteImageURLs(inHTML: html).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Original message")
                    .font(.headline)
                Spacer()
                if remoteImageCount > 0 && !imagesAllowed {
                    AinkradButton(title: "Load images (\(remoteImageCount))", style: .secondary,
                                  icon: "photo") {
                        imagesAllowed = true
                    }
                }
                AinkradIconButton(systemName: "xmark", tooltip: "Close", action: onClose)
            }
            .padding(AinkradSpacing.md)

            RawHTMLWebView(html: imagesAllowed ? html : Self.blockingRemoteImages(html))
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    /// Blanks every remote `<img src>` so the page cannot fetch a tracking
    /// pixel merely by being displayed. `cid:` inline images (which never
    /// leave the message) are left untouched, matching what
    /// `BodySanitizer.remoteImageURLs` itself treats as remote.
    static func blockingRemoteImages(_ html: String) -> String {
        var blocked = html
        for url in Set(BodySanitizer.remoteImageURLs(inHTML: html)) {
            blocked = blocked.replacingOccurrences(of: url, with: "about:blank")
        }
        return blocked
    }
}

private struct RawHTMLWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: nil)
    }
}
