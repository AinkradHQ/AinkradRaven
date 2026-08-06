import Testing
import Foundation
import AppKit
@testable import RavenFeature

/// The editor's two rules, both assertable without presenting anything:
/// **only allowlisted attributes cross between the model and the text view**,
/// and **every format command is undoable**.
///
/// The second is the specific bug the M6 design note names: `allowsUndo` covers
/// typing, paste and delete, but not programmatic mutation, so a format applied
/// by writing to `textStorage` directly leaves ⌘Z undoing the typing before it
/// and leaving the format behind.
@Suite("Compose rich editor")
@MainActor struct ComposeRichEditorTests {
    private let base = NSFont.systemFont(ofSize: 13)
    private let baseColor = NSColor.white

    private func textView(_ text: String) -> RichComposeTextView {
        let container = NSTextContainer(size: CGSize(width: 400, height: 10_000))
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let view = RichComposeTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 200),
                                       textContainer: container)
        view.isRichText = true
        view.allowsUndo = true
        view.baseFont = base
        view.baseColor = baseColor
        view.textStorage?.setAttributedString(
            RichTextBridge.attributedString(RichBody(plainText: text),
                                            font: base, color: baseColor))
        return view
    }

    private func spans(_ view: NSTextView) -> [RichBody.Span] {
        RichTextBridge.richBody(from: view.attributedString()).spans
    }

    // MARK: Model ↔ editor

    @Test("every supported kind survives the trip through the text view and back")
    func bridgeRoundTripsEveryKind() {
        let kinds: [RichBody.Kind] = [.bold, .italic, .underline, .code,
                                      .link(URL(string: "https://example.test/x")!),
                                      .bulletItem, .numberItem, .blockquote]
        let body = RichBody(text: "0123456789abcdefghij",
                            spans: kinds.enumerated().map {
                                RichBody.Span(start: $0.offset * 2, length: 2, kind: $0.element)
                            })

        let attributed = RichTextBridge.attributedString(body, font: base, color: baseColor)
        let back = RichTextBridge.richBody(from: attributed)

        #expect(back == body)
        #expect(back.spans.count == 8)
    }

    @Test("plain text makes the round trip with no formatting artefacts")
    func plainTextGainsNothing() {
        // The characters a converter would misread: emphasis marks, a dash
        // list, a quote prefix, a sigdash.
        let text = "**stars** and _underscores_\n- dash\n> quote\n-- \nSig"

        let back = RichTextBridge.richBody(
            from: RichTextBridge.attributedString(RichBody(plainText: text),
                                                  font: base, color: baseColor))

        #expect(back.text == text)
        #expect(back.spans.isEmpty)
    }

    @Test("bold is a font trait, never a colour, so the theme still owns every pixel of text")
    func boldCarriesNoColour() {
        let body = RichBody(text: "bold plain",
                            spans: [RichBody.Span(start: 0, length: 4, kind: .bold)])

        let attributed = RichTextBridge.attributedString(body, font: base, color: baseColor)

        var colours: [NSColor] = []
        var boldRanges: [NSRange] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attrs, range, _ in
            colours.append((attrs[.foregroundColor] as? NSColor) ?? .black)
            if let font = attrs[.font] as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                boldRanges.append(range)
            }
        }

        #expect(colours.allSatisfy { $0 == baseColor })
        #expect(boldRanges.map(\.length) == [4])
    }

    // MARK: Paste normalisation

    /// What AppKit's HTML reader hands back for a paragraph pasted out of a
    /// browser: the site's font at its own size, its colours, a background, and
    /// some real formatting mixed in.
    private func pastedFragment() -> NSAttributedString {
        let out = NSMutableAttributedString(string: "site text here")
        let whole = NSRange(location: 0, length: out.length)
        out.addAttributes([
            .font: NSFont(name: "Times New Roman", size: 24) ?? NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.systemPink,
            .backgroundColor: NSColor.systemYellow,
            .kern: 3.0
        ], range: whole)
        out.addAttribute(.font,
                         value: NSFontManager.shared.convert(
                            NSFont(name: "Times New Roman", size: 24)
                                ?? NSFont.systemFont(ofSize: 24), toHaveTrait: .boldFontMask),
                         range: NSRange(location: 0, length: 4))
        out.addAttribute(.link, value: URL(string: "https://example.test/from-the-page")!,
                         range: NSRange(location: 5, length: 4))
        return out
    }

    @Test("a paste keeps its bold and its link and loses the page's font, colours and size")
    func pasteIsNormalisedToTheAllowlist() throws {
        let view = textView("")
        let storage = try #require(view.textStorage)
        storage.setAttributedString(pastedFragment())

        RichTextBridge.normalize(storage, in: NSRange(location: 0, length: storage.length),
                                 font: base, color: baseColor)

        // Kept: the formatting the allowlist can express.
        let found = spans(view)
        #expect(found.contains { $0.kind == .bold && $0.start == 0 && $0.length == 4 })
        #expect(found.contains {
            $0.kind == .link(URL(string: "https://example.test/from-the-page")!)
        })
        // Gone: everything else. A recipient's dark mode and text-size
        // preference survive because none of this reaches the wire.
        storage.enumerateAttributes(
            in: NSRange(location: 0, length: storage.length)
        ) { attrs, _, _ in
            #expect(attrs[.backgroundColor] == nil)
            #expect(attrs[.kern] == nil)
            #expect(attrs[.foregroundColor] as? NSColor == baseColor)
            #expect((attrs[.font] as? NSFont)?.pointSize == base.pointSize)
        }
        // And the characters are all still there.
        #expect(view.string == "site text here")
    }

    /// Performs the part of `paste(_:)` that has no pasteboard in it: replace
    /// the selection with what AppKit's reader produced, leave the caret where
    /// the paste left it, then normalise. `paste(_:)` itself needs a real
    /// pasteboard; everything after the read is exercised here.
    private func simulatePaste(_ fragment: NSAttributedString, over selection: NSRange,
                               in view: RichComposeTextView) {
        view.setSelectedRange(selection)
        let start = selection.location
        // The insertion goes through the change cycle because `super.paste`
        // does, so what follows measures the editor's own behaviour rather
        // than an artefact of the simulation.
        guard view.shouldChangeText(in: selection, replacementString: fragment.string) else {
            Issue.record("the text view refused the simulated paste")
            return
        }
        view.textStorage?.replaceCharacters(in: selection, with: fragment)
        view.didChangeText()
        view.setSelectedRange(NSRange(location: start + fragment.length, length: 0))
        view.normalizePaste(startingAt: start)
    }

    private func foreignAttributes(_ storage: NSTextStorage, in range: NSRange) -> Int {
        var offenders = 0
        storage.enumerateAttributes(in: range) { attrs, subrange, _ in
            let bad = attrs[.backgroundColor] != nil || attrs[.kern] != nil
                || (attrs[.foregroundColor] as? NSColor) != baseColor
                || (attrs[.font] as? NSFont)?.pointSize != base.pointSize
            if bad { offenders += subrange.length }
        }
        return offenders
    }

    @Test("pasting over a selection normalises the whole insertion, not the length delta")
    func pasteOverSelectionNormalisesEverything() throws {
        let view = textView("keep OLD keep")
        let storage = try #require(view.textStorage)

        // 3 characters in, replacing "OLD" (3 units) with 14 — a net delta of
        // 11, so a delta-derived range would have left the last three
        // characters of the insertion carrying the page's styling.
        simulatePaste(pastedFragment(), over: NSRange(location: 5, length: 3), in: view)

        #expect(view.string == "keep site text here keep")
        #expect(foreignAttributes(storage, in: NSRange(location: 0, length: storage.length)) == 0)
        #expect(spans(view).contains { $0.kind == .bold })
    }

    @Test("pasting something shorter than the selection is still normalised")
    func pasteShorterThanSelectionIsNormalised() throws {
        let view = textView("keep 12345678901234 here")
        let storage = try #require(view.textStorage)

        // 14 digits replaced by 14 characters — a NET DELTA OF ZERO, the case
        // the delta-derived range skipped entirely: nothing was normalised and
        // the composer displayed the source's font, size and background.
        simulatePaste(pastedFragment(), over: NSRange(location: 5, length: 14), in: view)

        #expect(view.string == "keep site text here here")
        #expect(foreignAttributes(storage, in: NSRange(location: 0, length: storage.length)) == 0)
    }

    @Test("normalising a paste reports the change, so the document model is re-read")
    func pasteNormalisationReportsTheChange() throws {
        let view = textView("keep OLD keep")
        let watcher = ChangeWatcher()
        view.delegate = watcher

        simulatePaste(pastedFragment(), over: NSRange(location: 5, length: 3), in: view)

        // `didChangeText()` is what posts `textDidChange`, and that notification
        // is the ONLY thing that pushes the normalised document back into the
        // SwiftUI binding — `ComposeRichEditor.Coordinator.textDidChange` reads
        // `RichTextBridge.richBody(from:)` from it. Normalising outside the
        // change cycle leaves the binding holding what the raw paste produced
        // until the next keystroke happens to refresh it.
        //
        // Two: the simulated insertion (as `super.paste` would) and the
        // normalisation that follows it.
        #expect(watcher.changes == 2)
        #expect(view.string == "keep site text here keep")
    }

    /// Counts `textDidChange` the way the real coordinator receives it.
    private final class ChangeWatcher: NSObject, NSTextViewDelegate {
        var changes = 0
        func textDidChange(_ notification: Notification) { changes += 1 }
    }

    // MARK: Block geometry

    @Test("a bullet, a numbered item and a quote are visually distinguishable")
    func blockKindsLookDifferent() {
        func style(_ kind: RichBody.Kind) -> NSParagraphStyle {
            let body = RichBody(text: "a line", spans: [RichBody.Span(start: 0, length: 6,
                                                                      kind: kind)])
            let attributed = RichTextBridge.attributedString(body, font: base, color: baseColor)
            return (attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle) ?? NSParagraphStyle.default
        }

        let bullet = style(.bulletItem)
        let number = style(.numberItem)
        let quote = style(.blockquote)

        // Task 21 renders these as three different tags. Three identical-looking
        // paragraphs in the composer would be a UI lying about the document.
        #expect(bullet.headIndent != number.headIndent)
        #expect(quote.tailIndent != bullet.tailIndent)
        #expect(quote.tailIndent != number.tailIndent)
        #expect(quote.paragraphSpacingBefore > 0)
        #expect(bullet.paragraphSpacingBefore == 0)
        // And none of them touches a character.
        #expect(RichTextBridge.richBody(
            from: RichTextBridge.attributedString(
                RichBody(text: "a line",
                         spans: [RichBody.Span(start: 0, length: 6, kind: .bulletItem)]),
                font: base, color: baseColor)).text == "a line")
    }

    // MARK: Format commands

    @Test("a format command reaches the document model")
    func commandAppliesToTheModel() {
        let view = textView("hello there")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        RichTextCommand.toggle(.bold).apply(to: view)

        #expect(spans(view) == [RichBody.Span(start: 0, length: 5, kind: .bold)])
        #expect(view.string == "hello there")
    }

    @Test("a format command is undoable")
    func commandIsUndoable() {
        let view = textView("hello there")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        RichTextCommand.toggle(.bold).apply(to: view)
        #expect(spans(view).isEmpty == false)

        view.composerUndoManager.undo()

        // The bug this pins: a `textStorage` mutation that skipped the change
        // cycle would leave the bold here, undone by nothing.
        #expect(spans(view).isEmpty)
        #expect(view.string == "hello there")

        view.composerUndoManager.redo()
        #expect(spans(view) == [RichBody.Span(start: 0, length: 5, kind: .bold)])
    }

    @Test("applying a second kind keeps the first")
    func kindsCompose() {
        let view = textView("hello there")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        RichTextCommand.toggle(.bold).apply(to: view)
        RichTextCommand.toggle(.italic).apply(to: view)

        #expect(spans(view) == [RichBody.Span(start: 0, length: 5, kind: .bold),
                                RichBody.Span(start: 0, length: 5, kind: .italic)])
    }

    @Test("a kind split into two storage runs by a second kind reads back as one span")
    func adjacentRunsCoalesce() {
        let view = textView("hello there")
        // Bold over "hello", then italic over "he" only. The storage now holds
        // two runs — bold+italic, then bold — and the bold must still be ONE
        // span, or an identical document would encode differently depending on
        // the order the user pressed the buttons in.
        view.setSelectedRange(NSRange(location: 0, length: 5))
        RichTextCommand.toggle(.bold).apply(to: view)
        view.setSelectedRange(NSRange(location: 0, length: 2))
        RichTextCommand.toggle(.italic).apply(to: view)

        #expect(spans(view) == [RichBody.Span(start: 0, length: 5, kind: .bold),
                                RichBody.Span(start: 0, length: 2, kind: .italic)])
    }

    @Test("the same command twice turns the formatting off")
    func togglingTwiceRemoves() {
        let view = textView("hello there")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        RichTextCommand.toggle(.underline).apply(to: view)
        #expect(spans(view).map(\.kind) == [.underline])
        RichTextCommand.toggle(.underline).apply(to: view)

        #expect(spans(view).isEmpty)
    }

    @Test("clear formatting keeps every character and drops every attribute")
    func clearFormattingKeepsTheText() {
        let view = textView("hello there")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        RichTextCommand.toggle(.bold).apply(to: view)
        view.setSelectedRange(NSRange(location: 6, length: 5))
        RichTextCommand.toggle(.code).apply(to: view)

        view.setSelectedRange(NSRange(location: 0, length: 11))
        RichTextCommand.clearFormatting.apply(to: view)

        #expect(spans(view).isEmpty)
        #expect(view.string == "hello there")
    }

    @Test("a list command takes the whole paragraph, not the three selected characters")
    func blockCommandWidensToTheParagraph() {
        let view = textView("first line\nsecond line\nthird line")
        // Three characters in the middle of the second line.
        view.setSelectedRange(NSRange(location: 14, length: 3))

        RichTextCommand.toggle(.bulletItem).apply(to: view)

        let found = spans(view)
        #expect(found.count == 1)
        // "first line\n" is 11 units; the second paragraph runs to the next
        // newline inclusive.
        #expect(found.first?.start == 11)
        #expect(found.first?.length == 12)
        #expect(found.first?.kind == .bulletItem)
        #expect(view.string == "first line\nsecond line\nthird line")
    }

    @Test("a caret with nothing selected formats nothing")
    func caretOnlyIsANoOp() {
        let view = textView("hello there")
        view.setSelectedRange(NSRange(location: 3, length: 0))

        RichTextCommand.toggle(.bold).apply(to: view)

        #expect(spans(view).isEmpty)
    }
}
