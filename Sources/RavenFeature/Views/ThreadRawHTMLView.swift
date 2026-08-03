import SwiftUI
import AppKit
import WebKit
import Quartz
import AinkradAppKit
import AinkradAppKitUI

/// The raw-HTML "Show original" view.
///
/// Nothing in an unopened-sender's message may reach the network. The previous
/// implementation only blanked `<img src>` and claimed that was enough — CSS
/// `background-image`, `<link rel=stylesheet>`, `<iframe>` and `@font-face`
/// all still phoned home, and the `WKWebView` ran JavaScript with no
/// restrictions at all. The claim is now backed by three things, in order of
/// how much they are actually relied on:
///
/// 1. **A Content Security Policy injected ahead of the message markup**
///    (`RawHTMLWebView.policy`). This is the real control: `default-src 'none'`
///    denies every fetch WebKit can make — images, CSS, fonts, frames,
///    scripts, XHR — regardless of which element or stylesheet property
///    requests it. CSP composes restrictively, so a policy the message
///    supplies itself cannot widen ours.
/// 2. **JavaScript disabled** on the web view's configuration, so no script
///    can rewrite the DOM to route around the above.
/// 3. `blockingRemoteImages`, which still blanks remote `<img src>` values.
///    Belt-and-braces on top of the CSP, not the protection itself.
///
/// "Load images" re-loads with an image-permitting policy (scripts and frames
/// stay denied) and — for a sender not already allow-listed — persists the
/// choice via `RemoteImageAllowList` so future messages from the SAME sender
/// auto-load. A sender never seen before still defaults to blocked.
struct RawHTMLSheet: View {
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

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        // `spacing: 0` is a structural absence of a gap, not a spacing value:
        // the header sits flush on the web view by design.
        VStack(spacing: 0) {
            HStack(spacing: AinkradSpacing.sm) {
                Text("Original message")
                    .font(AinkradFontResolver.font(.headline, weight: .medium, typography: typo))
                    .foregroundStyle(theme.foreground)
                Spacer(minLength: AinkradSpacing.sm)
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

            RawHTMLWebView(html: imagesAllowed ? html : Self.blockingRemoteImages(html),
                           allowsRemoteLoads: imagesAllowed)
                .clipShape(ChamferShape(cut: AinkradRadius.sm))
        }
        // A fixed height, not a `minHeight`: this is presented inside
        // `.ainkradModal(contentWidth:)` now, whose content is offered the
        // width it asked for and is otherwise free to grow past the window.
        .frame(height: 480)
    }

    /// Blanks every remote `<img src>` so the page cannot fetch a tracking
    /// pixel merely by being displayed. `cid:` inline images (which never
    /// leave the message) are left untouched, matching what
    /// `BodySanitizer.remoteImageURLs` itself treats as remote.
    ///
    /// This is a second layer only — `RawHTMLWebView`'s CSP is what actually
    /// guarantees no remote load, including the ones this cannot see
    /// (`background-image`, `<link>`, `<iframe>`, `@font-face`).
    static func blockingRemoteImages(_ html: String) -> String {
        var blocked = html
        for url in Set(BodySanitizer.remoteImageURLs(inHTML: html)) {
            blocked = blocked.replacingOccurrences(of: url, with: "about:blank")
        }
        return blocked
    }
}

/// Renders one message's raw HTML with remote loading governed by a Content
/// Security Policy rather than by markup rewriting, and with JavaScript off in
/// both states.
struct RawHTMLWebView: NSViewRepresentable {
    let html: String
    /// False until the user (or a previous allow-list decision) opts in.
    let allowsRemoteLoads: Bool

    /// `default-src 'none'` is the whole point: it denies every fetch type
    /// WebKit has, so a remote reference introduced by a CSS property, a
    /// stylesheet `<link>`, an `<iframe>`, or an `@font-face` is refused
    /// without this code having to recognise the syntax that requested it.
    /// Inline styles stay allowed so the message is still readable, and `data:`
    /// / `cid:` images carry no network traffic.
    ///
    /// When images are allowed, exactly two source lists widen —
    /// `img-src`/`style-src`/`font-src` for presentation. `script-src`,
    /// `frame-src`, `object-src` and `connect-src` remain `'none'` in BOTH
    /// states: opting into a sender's images is not opting into their code.
    private var policy: String {
        let shared = "default-src 'none'; script-src 'none'; object-src 'none'; "
            + "frame-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'"
        return allowsRemoteLoads
            ? shared + "; img-src http: https: data: cid:; "
                + "style-src 'unsafe-inline' http: https:; font-src http: https: data:"
            : shared + "; img-src data: cid:; style-src 'unsafe-inline'"
    }

    /// The policy is prepended rather than merged into an existing `<head>`:
    /// WebKit hoists a leading `<meta http-equiv>` into the head it
    /// synthesises, and CSP intersects, so a policy the message declares for
    /// itself can only narrow this one further — never widen it.
    private var policedHTML: String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">\n" + html
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return configuration
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: makeConfiguration())
        view.loadHTMLString(policedHTML, baseURL: nil)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(policedHTML, baseURL: nil)
    }
}

/// Drives one `QLPreviewPanel` showing one fetched attachment's temp file
/// (`AttachmentPreviewFile`), and removes that temp file when the panel
/// closes — the "held only for the open thread, never cached to disk
/// indefinitely" contract extends to this one on-disk exception.
final class QuickLookAttachmentPreviewer: NSObject, QLPreviewPanelDataSource,
    QLPreviewPanelDelegate {
    private let file: AttachmentPreviewFile
    private var onClose: (() -> Void)?

    init(file: AttachmentPreviewFile) {
        self.file = file
    }

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        guard let panel = QLPreviewPanel.shared() else { onClose(); cleanUpNow(); return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(panelWillClose),
                                               name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func panelWillClose() {
        NotificationCenter.default.removeObserver(self)
        cleanUpNow()
    }

    private func cleanUpNow() {
        file.cleanUp()
        onClose?()
        onClose = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        file.url as NSURL
    }
}
