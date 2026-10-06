import AppKit

/// One formatting action, and the only way the format bar is allowed to change
/// the document.
///
/// **Every command goes through `shouldChangeText`/`didChangeText` and
/// registers its own undo.** A format applied by mutating `textStorage`
/// directly is invisible to `NSTextView`'s undo stack: the user presses ⌘Z,
/// the typing before the format is undone, and the format stays — the specific
/// bug this type exists to make impossible. `allowsUndo` covers typing, paste
/// and delete; it does NOT cover programmatic mutation.
enum RichTextCommand: Equatable {
    /// Applies the kind if the selection does not already have it throughout,
    /// removes it if it does.
    case toggle(RichBody.Kind)
    /// Back to the composer's own font and colour, keeping every character.
    case clearFormatting

    /// Runs the command against `textView`'s current selection. A caret with no
    /// selection is a no-op — there is no range to format, and silently
    /// formatting the surrounding word would be a guess.
    @MainActor func apply(to textView: NSTextView) {
        let range = effectiveRange(in: textView)
        guard range.length > 0, let storage = textView.textStorage else { return }
        let baseFont =
            (textView as? RichComposeTextView)?.baseFont
            ?? textView.font ?? .systemFont(ofSize: 13)
        let baseColor =
            (textView as? RichComposeTextView)?.baseColor
            ?? textView.textColor ?? .textColor
        Self.mutate(textView, range: range) {
            switch self {
            case .clearFormatting:
                storage.setAttributes(
                    [.font: baseFont, .foregroundColor: baseColor],
                    range: range)
            case .toggle(let kind):
                if Self.covers(kind, storage, range) {
                    Self.remove(kind, from: storage, range: range, baseFont: baseFont)
                } else {
                    // Read what is already there, reset to the composer's own
                    // font and colour, then re-apply the old kinds and the new
                    // one together. The reset is what keeps a run that was
                    // pasted from somewhere with its own font from surviving a
                    // format command — the allowlist is applied on this path
                    // exactly as it is on paste.
                    let existing = RichTextBridge.spans(in: storage, range: range)
                    storage.setAttributes(
                        [.font: baseFont, .foregroundColor: baseColor],
                        range: range)
                    let added = RichBody.Span(
                        start: range.location, length: range.length,
                        kind: kind)
                    for span in existing + [added] {
                        RichTextBridge.applyKind(
                            span.kind, to: storage,
                            range: NSRange(location: span.start, length: span.length),
                            baseFont: baseFont)
                    }
                }
            }
        }
    }

    /// Block kinds address whole paragraphs — a bullet is a property of a line,
    /// not of three characters in the middle of it — so the selection is
    /// widened to paragraph bounds for them and used verbatim otherwise.
    @MainActor private func effectiveRange(in textView: NSTextView) -> NSRange {
        let selected = textView.selectedRange()
        guard case .toggle(let kind) = self, kind.isBlock else { return selected }
        return (textView.string as NSString).paragraphRange(for: selected)
    }

    private static func covers(
        _ kind: RichBody.Kind, _ storage: NSTextStorage,
        _ range: NSRange
    ) -> Bool {
        RichTextBridge.spans(in: storage, range: range).contains {
            $0.kind == kind && $0.start <= range.location
                && $0.start + $0.length >= NSMaxRange(range)
        }
    }

    private static func remove(
        _ kind: RichBody.Kind, from storage: NSTextStorage,
        range: NSRange, baseFont: NSFont
    ) {
        switch kind {
        case .bold: removeTrait(.boldFontMask, from: storage, range: range)
        case .italic: removeTrait(.italicFontMask, from: storage, range: range)
        case .underline: storage.removeAttribute(.underlineStyle, range: range)
        case .code:
            storage.removeAttribute(RichTextBridge.codeAttribute, range: range)
            storage.addAttribute(.font, value: baseFont, range: range)
        case .link: storage.removeAttribute(.link, range: range)
        case .bulletItem, .numberItem, .blockquote:
            storage.removeAttribute(RichTextBridge.blockAttribute, range: range)
            storage.removeAttribute(.paragraphStyle, range: range)
        }
    }

    private static func removeTrait(
        _ trait: NSFontTraitMask, from storage: NSTextStorage,
        range: NSRange
    ) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(
                .font, value: NSFontManager.shared.convert(font, toNotHaveTrait: trait),
                range: sub)
        }
    }

    /// Performs `change` inside the text view's own change cycle.
    ///
    /// `shouldChangeText(in:replacementString: nil)` is the attribute-only
    /// form: it tells the text view an attribute change is coming over `range`,
    /// which is what makes the view capture the previous attributes for its
    /// undo stack; `didChangeText()` closes the cycle and posts the change
    /// notification the coordinator reads the model back from. Writing to
    /// `textStorage` outside this pair does neither — the format would be
    /// invisible to ⌘Z and invisible to the binding until the next keystroke.
    /// `ComposeRichEditorTests.commandIsUndoable` is what holds this in place;
    /// it fails if the pair is bypassed.
    @MainActor private static func mutate(
        _ textView: NSTextView, range: NSRange,
        _ change: () -> Void
    ) {
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        change()
        textView.didChangeText()
    }
}

extension RichBody.Kind {
    /// Whether this kind describes a whole paragraph rather than a run inside
    /// one.
    /// Exhaustive, with no `default:` — a kind added later must be classified
    /// here deliberately. A `default` would silently treat a new BLOCK kind as
    /// an inline one, so a list command would format three selected characters
    /// instead of the paragraph.
    var isBlock: Bool {
        switch self {
        case .bulletItem, .numberItem, .blockquote: return true
        case .bold, .italic, .underline, .code, .link: return false
        }
    }
}
