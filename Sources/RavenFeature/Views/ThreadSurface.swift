import SwiftUI
import AppKit
import WebKit
import AinkradAppKit
import AinkradAppKitUI

/// Renders `model.selectedThread`. Defaults to the sanitized plain text
/// (`MessageBody.plainText`) — per `BodySanitizer`'s own contract, that text
/// must never be re-rendered as HTML or Markdown, only as plain text — and
/// offers "Show original" to open the raw HTML in a `WKWebView`.
///
/// Also owns Reply/Reply-all/Forward: an inline compose panel (never a new
/// window) that reuses `RavenRuntime.sendThreadReply`, which is the exact same
/// queue→drain→classify path (`SendAttempt`) every other send in this app
/// goes through.
public struct ThreadSurface: View {
    @Bindable var model: RavenViewModel
    let runtime: RavenRuntime

    public init(model: RavenViewModel, runtime: RavenRuntime) {
        self.model = model
        self.runtime = runtime
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thread = model.selectedThread {
                header(thread)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                        ForEach(thread.messages, id: \.id) { message in
                            MessageRow(message: message, runtime: runtime)
                        }
                        ReplyPanel(thread: thread, runtime: runtime)
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
/// the quoted trailer `QuoteTrimmer` split off, attachment chips, and "Show
/// original".
private struct MessageRow: View {
    let message: MailMessage
    let runtime: RavenRuntime

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

            if !message.attachments.isEmpty {
                AttachmentChipRow(attachments: message.attachments, messageID: message.id,
                                  runtime: runtime)
            }
        }
        .padding(AinkradSpacing.md)
        .background(ChamferShape(cut: 8).fill(Color.primary.opacity(0.03)))
        .task(id: message.id) {
            guard loadedBody == nil else { return }
            isLoading = true
            loadedBody = await runtime.loadBody(for: message)
            isLoading = false
        }
        .sheet(isPresented: $showingOriginal) {
            if let html = loadedBody?.html {
                RawHTMLSheet(html: html, sender: message.from?.email, runtime: runtime,
                            onClose: { showingOriginal = false })
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

/// Attachment metadata as `AinkradChip`s. Tapping one fetches the bytes on
/// demand (in-memory only — never written to a cache directory) and hands
/// them to an `NSSavePanel`. See the task report for this fetch path's exact
/// wiring status.
private struct AttachmentChipRow: View {
    let attachments: [MailAttachment]
    let messageID: String
    let runtime: RavenRuntime

    @State private var downloadingID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack(spacing: AinkradSpacing.xs) {
                ForEach(attachments, id: \.attachmentID) { attachment in
                    AinkradChip(label: chipLabel(attachment), systemName: "paperclip")
                        .opacity(downloadingID == attachment.attachmentID ? 0.5 : 1)
                        .onTapGesture { download(attachment) }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func chipLabel(_ attachment: MailAttachment) -> String {
        let sizeKB = attachment.size / 1024
        return sizeKB > 0 ? "\(attachment.filename) (\(sizeKB) KB)" : attachment.filename
    }

    private func download(_ attachment: MailAttachment) {
        guard downloadingID == nil else { return }
        downloadingID = attachment.attachmentID
        errorMessage = nil
        Task {
            let data = await runtime.fetchAttachment(attachment, messageID: messageID)
            downloadingID = nil
            guard let data else {
                errorMessage = "Could not download \(attachment.filename)."
                return
            }
            savePanel(data: data, suggestedName: attachment.filename)
        }
    }

    /// `NSSavePanel` is the one disk write this flow performs, and only after
    /// the user explicitly picks a destination — the fetched bytes otherwise
    /// live only in memory, never in a cache directory.
    private func savePanel(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}

/// The raw-HTML "Show original" view. Remote images are stripped out of the
/// markup before it is loaded, so nothing phones home to a tracking pixel
/// merely by opening this sheet; "Load images" re-loads the untouched HTML
/// for this viewing and — for a sender not already allow-listed — persists
/// the choice via `RemoteImageAllowList` so future messages from the SAME
/// sender auto-load. A sender never seen before still defaults to blocked.
private struct RawHTMLSheet: View {
    let html: String
    let sender: String?
    let runtime: RavenRuntime
    let onClose: () -> Void
    @State private var imagesAllowed: Bool

    init(html: String, sender: String?, runtime: RavenRuntime, onClose: @escaping () -> Void) {
        self.html = html
        self.sender = sender
        self.runtime = runtime
        self.onClose = onClose
        _imagesAllowed = State(initialValue: sender.map(runtime.imagesAllowed(for:)) ?? false)
    }

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
                        if let sender { runtime.allowImages(for: sender) }
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

/// The inline Reply/Reply-all/Forward panel. Choosing an action pre-fills the
/// composer via `ReplyComposer`; Send routes through
/// `RavenRuntime.sendThreadReply`, the same `SendAttempt` path every other
/// send in the app uses.
private struct ReplyPanel: View {
    let thread: MailThread
    let runtime: RavenRuntime

    @State private var mode: ReplyComposer.Mode?
    @State private var to = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var isSending = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradButton(title: "Reply", style: .secondary, icon: "arrowshape.turn.up.left") {
                    open(.reply)
                }
                AinkradButton(title: "Reply All", style: .secondary, icon: "arrowshape.turn.up.left.2") {
                    open(.replyAll)
                }
                AinkradButton(title: "Forward", style: .secondary, icon: "arrowshape.turn.up.right") {
                    open(.forward)
                }
            }

            if mode != nil {
                AinkradTextField(text: $to, placeholder: "To")
                AinkradTextField(text: $subject, placeholder: "Subject")
                AinkradTextArea(text: $bodyText, placeholder: "Write your message…", minHeight: 160)

                if let statusMessage {
                    AinkradBanner(message: statusMessage, status: statusIsError ? .danger : .warning,
                                  onDismiss: { self.statusMessage = nil })
                }

                HStack {
                    AinkradButton(title: "Cancel", style: .secondary) { mode = nil }
                    Spacer()
                    AinkradButton(title: "Send", style: .primary, icon: "paperplane",
                                  isLoading: isSending, action: send)
                        .disabled(isSending || (mode != .forward && recipients.isEmpty))
                }
            }
        }
        .padding(AinkradSpacing.md)
    }

    private var recipients: [MailAddress] {
        to.split(separator: ",").compactMap { MailAddress(rfc5322: String($0)) }
    }

    private func open(_ newMode: ReplyComposer.Mode) {
        guard let last = thread.messages.last else { return }
        statusMessage = nil
        let body = runtime.store.body(messageID: last.id)?.plainText ?? ""
        let draft = ReplyComposer.compose(mode: newMode, thread: thread, lastMessage: last,
                                          lastMessageBody: body, ownAddress: runtime.ownAddress)
        mode = newMode
        to = draft.to.map(\.email).joined(separator: ", ")
        subject = draft.subject
        bodyText = draft.bodyText
    }

    private func send() {
        guard mode == .forward || !recipients.isEmpty else { return }
        isSending = true
        statusMessage = nil
        let outgoing = OutgoingMessage(
            to: recipients, subject: subject, bodyText: bodyText,
            inReplyToMessageID: mode == .forward ? nil : thread.messages.last?.rfc822MessageID,
            threadID: mode == .forward ? nil : thread.id)
        Task {
            do {
                let result = try await runtime.sendThreadReply(outgoing)
                if result.isSent {
                    mode = nil
                    to = ""; subject = ""; bodyText = ""
                } else {
                    statusMessage = result.message
                    statusIsError = !result.outcome.isBenign
                }
            } catch {
                statusMessage = "Could not queue send: \(error)."
                statusIsError = true
            }
            isSending = false
        }
    }
}
