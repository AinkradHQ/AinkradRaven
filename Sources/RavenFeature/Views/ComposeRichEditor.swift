import SwiftUI
import AppKit
import AinkradAppKit
import AinkradAppKitUI

/// The compose body field: a rich-text editor over `RichBody`, plus the format
/// bar above it.
///
/// **Why AppKit, and why here.** SwiftUI's attributed-string editor
/// (`TextEditor(text: Binding<AttributedString>)`) is macOS 15; this plugin's
/// deployment target is 14.0 and must stay at the host's floor, so taking it
/// would mean a plugin that does not load rather than one with thinner
/// formatting. And promoting this into AinkradAppKitUI would gate Raven on a
/// host kit release — the plugin `dlopen`s against the host's *shipped* kit
/// revision, so a new kit symbol is a symbol Raven cannot link. Everything used
/// below (`ainkradTheme`, `AinkradFontResolver`, `ChamferShape`,
/// `AinkradSpacing`) is already in that shipped ABI.
struct ComposeBodyField: View {
    @Binding var richBody: RichBody
    let placeholder: String
    let minHeight: CGFloat

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    /// Editing state reported up from the `NSTextView` — SwiftUI's
    /// `@FocusState` does not track an `NSViewRepresentable`, so the chamfer
    /// focus ring is driven from this instead. Same approach the kit's own
    /// `AutoGrowingTextView` takes.
    @State private var isEditing = false
    /// The live text view, for the format bar to act on. Held by a reference
    /// box rather than passed as a binding because a command mutates AppKit
    /// state, and routing that through SwiftUI state would rebuild the view
    /// mid-edit and lose the selection the command is about to use.
    @State private var handle = ComposeEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            ComposeFormatBar(handle: handle)
            editorSurface
        }
        // **Base text direction, set — not implemented.**
        //
        // An Arabic message typed into an implicitly left-to-right editor has
        // its cursor, its alignment and its punctuation on the wrong side, and
        // the same message arrives laid out left-to-right at the far end.
        // Handing the direction to the system (and, in the sent message, to an
        // HTML `dir` attribute) lets the Unicode bidi algorithm do the
        // reordering it already does correctly. The only thing it cannot infer
        // is the paragraph's base direction, and that is the one thing set here.
        //
        // Scoped to the editor alone, deliberately: mirroring the whole
        // composer would move the Send button and the drafts rail, which are
        // app chrome and belong wherever the host's layout direction puts them.
        //
        // It reads `richBody.text`, which IS the plain body — the same string
        // that used to be `bodyText`, so detection is unchanged.
        .environment(\.layoutDirection,
                     BaseTextDirection.detect(richBody.text) == .rightToLeft
                        ? .rightToLeft : .leftToRight)
    }

    private var editorSurface: some View {
        ZStack(alignment: .topLeading) {
            if richBody.text.isEmpty {
                // Insets match the text view's own text origin
                // (`textContainerInset` + line-fragment padding) so the
                // placeholder sits where typed text will.
                Text(placeholder)
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.4))
                    .padding(.horizontal, AinkradSpacing.md + 5)
                    .padding(.vertical, AinkradSpacing.sm)
                    .allowsHitTesting(false)
            }
            ComposeRichEditor(richBody: $richBody,
                              handle: handle,
                              font: bodyFont,
                              textColor: NSColor(theme.foreground),
                              tintColor: NSColor(theme.accentSecondary),
                              onFocusChange: { isEditing = $0 })
        }
        .frame(minHeight: minHeight)
        .background(ChamferShape(cut: 8).fill(theme.surfaceElevated.opacity(0.5)))
        .overlay(ChamferShape(cut: 8).strokeBorder(
            theme.accentPrimary.opacity(isEditing ? 0.9 : 0.25),
            lineWidth: isEditing ? 1.5 : 1.25))
        .shadow(color: theme.accentSecondary.opacity(isEditing ? 0.4 : 0),
                radius: isEditing ? 6 : 0)
        .animation(AinkradMotion.hover, value: isEditing)
    }

    /// The kit's own resolution, not a hardcoded size: the host's typography
    /// scale and font family decide, and a live change repaints because
    /// `updateNSView` re-applies it.
    private var bodyFont: NSFont {
        let size = AinkradFontResolver.pointSize(.body, typography: typo)
        if let family = typo.fontFamilyName, let f = NSFont(name: family, size: size) { return f }
        return NSFont.systemFont(ofSize: size)
    }
}

/// A handle on the live editor, so the format bar can act on the selection.
@MainActor final class ComposeEditorHandle {
    weak var textView: NSTextView?
}

/// The `NSTextView` itself. `isRichText = true`, themed entirely from the
/// values handed in — the view holds no colour of its own.
struct ComposeRichEditor: NSViewRepresentable {
    @Binding var richBody: RichBody
    let handle: ComposeEditorHandle
    let font: NSFont
    let textColor: NSColor
    let tintColor: NSColor
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than via `NSTextView.scrollableTextView()`,
        // which vends a plain `NSTextView` — the paste override below lives on
        // a subclass, so the subclass has to be the one instantiated.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let huge = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: CGSize(width: 0, height: huge))
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let tv = RichComposeTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.minSize = CGSize(width: 0, height: 0)
        tv.maxSize = CGSize(width: huge, height: huge)
        scroll.documentView = tv
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        // `drawsBackground = false` so the `ChamferShape` behind the editor
        // shows through; every other colour comes from the theme values above.
        tv.drawsBackground = false
        tv.textContainerInset = CGSize(width: AinkradSpacing.md, height: AinkradSpacing.sm)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        apply(theme: tv)
        tv.textStorage?.setAttributedString(
            RichTextBridge.attributedString(richBody, font: font, color: textColor))
        handle.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? RichComposeTextView else { return }
        handle.textView = tv
        // Re-applied every update so a live theme change repaints.
        apply(theme: tv)
        // Only when the model genuinely differs from what is on screen —
        // rewriting the storage on every render would destroy the selection
        // and the undo stack on every keystroke.
        guard RichTextBridge.richBody(from: tv.attributedString()) != richBody else { return }
        let selection = tv.selectedRange()
        tv.textStorage?.setAttributedString(
            RichTextBridge.attributedString(richBody, font: font, color: textColor))
        let count = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(selection.location, count), length: 0))
    }

    private func apply(theme tv: RichComposeTextView) {
        tv.baseFont = font
        tv.baseColor = textColor
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = tintColor
        tv.typingAttributes = [.font: font, .foregroundColor: textColor]
        // The allowlist carries no colours, so the whole document is re-tinted
        // on a theme change and nothing in it can be invisible against the new
        // background.
        if let storage = tv.textStorage, storage.length > 0 {
            storage.addAttribute(.foregroundColor, value: textColor,
                                 range: NSRange(location: 0, length: storage.length))
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeRichEditor
        init(_ parent: ComposeRichEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.richBody = RichTextBridge.richBody(from: tv.attributedString())
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }
    }
}

/// The text view, subclassed for one reason: **paste normalisation.**
///
/// `isRichText = true` already reads `public.rtf` and `public.html` through
/// AppKit's own reader, and we do not want its raw result — a paragraph pasted
/// out of a browser arrives carrying the site's font stack, pixel sizes,
/// colours and background. So the superclass performs the read and the
/// inserted range is then normalised in place against the allowlist: anything
/// not on it is stripped, anything on it is kept.
///
/// This is also why nothing needs an HTML→HTML sanitiser. Pasted HTML is never
/// rendered and never transmitted — AppKit parses it once, into attributes,
/// and every attribute we do not recognise is discarded here. A `<script>`, a
/// tracking pixel or a remote stylesheet cannot survive into a sent message,
/// not because it was sanitised but because it was never represented.
final class RichComposeTextView: NSTextView {
    var baseFont: NSFont = .systemFont(ofSize: 13)
    var baseColor: NSColor = .textColor

    /// The composer's own undo stack.
    ///
    /// `NSResponder.undoManager` walks the responder chain to the window's,
    /// which in a HUD overlay is shared with every other field in it — undoing
    /// in the body would then interleave with edits made elsewhere. Owning one
    /// also means the stack exists whether or not this view is in a window,
    /// which is what makes the format-bar undo behaviour assertable.
    let composerUndoManager = UndoManager()

    override var undoManager: UndoManager? { composerUndoManager }

    /// `super.paste`, not `pasteAsRichText`: the superclass picks the
    /// representation from `readablePasteboardTypes`, which is what leaves
    /// ⌘⇧V (`pasteAsPlainText:`, not overridden) meaning plain text. Forcing
    /// the rich read here took that intent away from the user.
    override func paste(_ sender: Any?) {
        let start = selectedRange().location
        super.paste(sender)
        normalizePaste(startingAt: start)
    }

    /// Normalises everything a paste that began at `start` inserted.
    ///
    /// The length comes from where the caret ENDED UP, not from a
    /// before/after length delta. Pasting over a selection replaces N
    /// characters with M: the delta is `M - N`, so a delta-derived range
    /// normalised only part of the insertion and left its tail carrying the
    /// source's font, size, background and kerning — and when `M <= N` the
    /// range was empty or negative and NOTHING was normalised, which is the
    /// ordinary "select a paragraph and paste over it" case.
    ///
    /// Wrapped in the text view's change cycle for the same reason every
    /// format command is. What that buys, precisely: `shouldChangeText` gives
    /// the delegate its veto, and `didChangeText()` posts the `textDidChange`
    /// the coordinator re-reads the document model from — without it the
    /// SwiftUI binding holds what the RAW paste produced until some later
    /// keystroke refreshes it. It is NOT what makes the paste undoable:
    /// `super.paste` already registered the insertion, and undo/redo of it
    /// preserves the normalisation either way (measured, not assumed — a
    /// mutation removing this pair leaves every undo/redo assertion green,
    /// which is why the test asserts the notification instead).
    ///
    /// Internal so it can be exercised without a pasteboard — `paste(_:)`
    /// itself needs a real one, this does not.
    func normalizePaste(startingAt start: Int) {
        guard let storage = textStorage else { return }
        let length = selectedRange().location - start
        guard start >= 0, length > 0, start + length <= storage.length else { return }
        let range = NSRange(location: start, length: length)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        RichTextBridge.normalize(storage, in: range, font: baseFont, color: baseColor)
        didChangeText()
    }
}
