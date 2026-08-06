import Foundation

/// Renders a `RichBody` — plain text plus out-of-band spans — into the minimal
/// HTML fragment that becomes the `text/html` part of an outgoing
/// `multipart/alternative` message.
///
/// ## Why this exists rather than `NSAttributedString`'s HTML writer
///
/// `NSAttributedString.data(from:documentAttributes:[.documentType: .html])`
/// does not emit a fragment; it emits a whole
/// `<html><head><style>…</style></head><body>` document, so a client that
/// inlines the part into its own document gets a nested `<html>`. Its style
/// output names the *sender's* local system font at absolute pixel sizes and
/// writes explicit colours, which overrides the recipient's text-size
/// preference and defeats their dark mode. Gmail drops the `<head>` the class
/// names depend on, and Outlook renders the remainder through the Word engine.
/// And it is not stable across macOS versions, so it **cannot be asserted in a
/// test** — disqualifying on its own for a body whose MIME assembly is covered
/// by byte-level assertions. See the M6 rich-compose design note, decision 3.
///
/// ## The tag table
///
/// The same fixed-table discipline `MarkdownToHTML` establishes: structural
/// tags come from the hard-coded tables in `openTag(for:)` / `blockTags(for:)`
/// below and nowhere else, so no attacker-controlled string can become a tag or
/// an attribute name, and every run of literal text goes through
/// `MarkdownToHTML.escape` — including a link's `href`, which is escaped rather
/// than trusted.
///
/// Emitted: `<p> <br> <strong> <em> <u> <code> <a> <ul> <ol> <li> <blockquote>`
/// (plus the `<div class="sig">` wrapper `MarkdownToHTML.renderComposed`
/// already emits, from the shared signature branch below). Deliberately absent:
/// `<style>`, `style=`, `class=` on anything but the sigdash wrapper, colours,
/// font families and sizes — the recipient's client picks the font.
///
/// This table is a strict SUBSET of `MarkdownToHTML`'s, which additionally
/// emits `<h1>`–`<h6>`, `<pre><code>`, `<hr>`, `<table>`, `<tr>` and `<td>`
/// because Markdown can express those and `RichBody.Kind` cannot. Every tag
/// this renderer can emit, that one can too, and both spell the same construct
/// the same way — so the two renderers cannot drift into producing different
/// markup for the same visible formatting. Widening the set later is easy;
/// narrowing it is not, because a tag that has been emitted exists in sent mail
/// that people will quote back.
///
/// ## What it shares with `MarkdownToHTML`, and why
///
/// Signature and quote splitting are NOT reimplemented here: `Signature.split`
/// and `QuotedRegion.split` are called by both renderers, on the same string,
/// and the signature and quoted regions are rendered through the same
/// `MarkdownToHTML.literalLines`. That works only because `RichBody.text` *is*
/// the plain text — so the two splitters see exactly the characters they see on
/// the `nil`-rich-body path, and a reply's quoted trailer cannot render one way
/// when it was typed with formatting and another way when it was not.
enum RichBodyHTML {
    /// Renders a *composed* body: typed text (through the span table) →
    /// signature (literal) → quoted original (literal). The same emission order
    /// `MarkdownToHTML.renderComposed` uses, for the same reason — the
    /// signature belongs to the new message, not to the thing being quoted.
    static func renderComposed(_ body: RichBody) -> String {
        // Signature first: it is appended last, so it is the outermost layer.
        let (withoutSignature, signature) = Signature.split(body.text)
        let quote = QuotedRegion.split(withoutSignature)

        // `QuoteTrimmer.split` TRIMS the visible half, so the typed region is
        // not necessarily at offset zero of `body.text` and the spans must be
        // rebased before they can address it. Anything else silently shifts
        // every run by the number of leading whitespace characters.
        let typedStart = utf16Offset(ofFirst: quote.body, in: withoutSignature)
        let typedSpans = rebase(body.spans, start: typedStart,
                                length: quote.body.utf16.count)

        var html = render(quote.body, spans: typedSpans)
        if let signature {
            html += "<div class=\"sig\">-- <br>\(MarkdownToHTML.literalLines(signature))</div>"
        }
        if let quotedLines = quote.quotedLines {
            if let attribution = quote.attribution {
                html += "<p>\(MarkdownToHTML.escape(attribution))</p>"
            }
            html += "<blockquote>"
                + MarkdownToHTML.literalLines(quotedLines.joined(separator: "\n"))
                + "</blockquote>"
        }
        return html
    }

    /// Renders one region of text with spans whose offsets are relative to it.
    static func render(_ text: String, spans: [RichBody.Span]) -> String {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return "" }
        let lines = split(units)

        var html = ""
        var index = 0
        while index < lines.count {
            let kind = blockKind(for: lines[index], spans: spans)
            var end = index + 1
            while end < lines.count && blockKind(for: lines[end], spans: spans) == kind {
                end += 1
            }
            html += renderGroup(Array(lines[index..<end]), kind: kind,
                                units: units, spans: spans)
            index = end
        }
        return html
    }

    // MARK: - Lines

    /// One line of the region, as a half-open range of UTF-16 code units into
    /// it. Ranges rather than substrings because every span offset is a UTF-16
    /// offset, so slicing anywhere else would need a conversion per line.
    private struct Line {
        let start: Int
        let end: Int
    }

    /// Splits on `\n`, `\r\n` and a bare `\r`, WITHOUT normalising them first:
    /// a normalisation pass would rewrite the string the spans are measured
    /// against and shift every offset after the first `\r\n`.
    private static func split(_ units: [UInt16]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x0A {
                lines.append(Line(start: start, end: index))
                index += 1
                start = index
            } else if unit == 0x0D {
                lines.append(Line(start: start, end: index))
                index += 1
                if index < units.count && units[index] == 0x0A { index += 1 }
                start = index
            } else {
                index += 1
            }
        }
        lines.append(Line(start: start, end: units.count))
        return lines
    }

    // MARK: - Block structure

    /// The block-level formatting kinds. A line belongs to at most one, and a
    /// run of adjacent lines sharing one becomes a single element.
    private enum Block: Equatable {
        case bullet
        case number
        case quote
    }

    private static func block(for kind: RichBody.Kind) -> Block? {
        switch kind {
        case .bulletItem: return .bullet
        case .numberItem: return .number
        case .blockquote: return .quote
        case .bold, .italic, .underline, .code, .link: return nil
        }
    }

    /// The block a line belongs to: the first span, in stored order, that both
    /// is a block kind and addresses at least one character of the line. An
    /// empty line is in no block — which is what makes a blank line end a list.
    private static func blockKind(for line: Line, spans: [RichBody.Span]) -> Block? {
        for span in spans {
            guard let block = block(for: span.kind) else { continue }
            if span.start < line.end && line.start < span.start + span.length { return block }
        }
        return nil
    }

    /// Opening/closing tags for a block group. The other hard-coded table.
    private static func blockTags(for block: Block) -> (String, String) {
        switch block {
        case .bullet: return ("<ul>", "</ul>")
        case .number: return ("<ol>", "</ol>")
        case .quote: return ("<blockquote>", "</blockquote>")
        }
    }

    private static func renderGroup(_ lines: [Line], kind: Block?,
                                    units: [UInt16], spans: [RichBody.Span]) -> String {
        guard let kind else { return paragraphs(lines, units: units, spans: spans) }
        let (open, close) = blockTags(for: kind)
        let inner: String
        switch kind {
        case .bullet, .number:
            inner = lines.map { "<li>\(inline($0, units: units, spans: spans))</li>" }.joined()
        case .quote:
            inner = paragraphs(lines, units: units, spans: spans)
        }
        return inner.isEmpty ? "" : open + inner + close
    }

    /// Runs of adjacent non-blank lines become one `<p>` with `<br>` between
    /// them; a blank line separates paragraphs. Line breaks are preserved
    /// because the user pressed Return — unlike Markdown, where a single
    /// newline is a soft break the parser folds away.
    private static func paragraphs(_ lines: [Line], units: [UInt16],
                                   spans: [RichBody.Span]) -> String {
        var html = ""
        var current: [String] = []
        func flush() {
            if !current.isEmpty { html += "<p>\(current.joined(separator: "<br>"))</p>" }
            current = []
        }
        for line in lines {
            if isBlank(line, units: units) {
                flush()
            } else {
                current.append(inline(line, units: units, spans: spans))
            }
        }
        flush()
        return html
    }

    private static func isBlank(_ line: Line, units: [UInt16]) -> Bool {
        for index in line.start..<line.end where units[index] != 0x20 && units[index] != 0x09 {
            return false
        }
        return true
    }

    // MARK: - Inline formatting

    /// The inline attributes in force at one position. A set rather than a
    /// nesting stack because spans may overlap arbitrarily — the editor imposes
    /// no nesting — and a fixed emission order below turns any overlap into
    /// well-formed markup.
    private struct Attributes: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var code = false
        var link: URL?

        var isPlain: Bool {
            !bold && !italic && !underline && !code && link == nil
        }
    }

    private static func inline(_ line: Line, units: [UInt16],
                               spans: [RichBody.Span]) -> String {
        let length = line.end - line.start
        guard length > 0 else { return "" }
        var attributes = [Attributes](repeating: Attributes(), count: length)
        for span in spans {
            let from = max(span.start, line.start)
            let to = min(span.start + span.length, line.end)
            guard from < to else { continue }
            for index in from..<to {
                apply(span.kind, to: &attributes[index - line.start])
            }
        }

        var html = ""
        var runStart = 0
        while runStart < length {
            var runEnd = runStart + 1
            while runEnd < length && attributes[runEnd] == attributes[runStart] { runEnd += 1 }
            let text = String(decoding: units[(line.start + runStart)..<(line.start + runEnd)],
                              as: UTF16.self)
            html += wrap(MarkdownToHTML.escape(text), in: attributes[runStart])
            runStart = runEnd
        }
        return html
    }

    private static func apply(_ kind: RichBody.Kind, to attributes: inout Attributes) {
        switch kind {
        case .bold: attributes.bold = true
        case .italic: attributes.italic = true
        case .underline: attributes.underline = true
        case .code: attributes.code = true
        case .link(let url): attributes.link = url
        case .bulletItem, .numberItem, .blockquote: break
        }
    }

    /// Innermost-to-outermost: `code`, `em`, `strong`, `u`, `a`. The first three
    /// are in `MarkdownToHTML.renderInline`'s order, so a bold-italic run is
    /// spelled identically by both renderers; `<u>` has no Markdown spelling and
    /// sits outside them, and the anchor is always outermost so a partially
    /// formatted link is one `<a>` rather than several.
    private static func wrap(_ escaped: String, in attributes: Attributes) -> String {
        guard !escaped.isEmpty else { return "" }
        guard !attributes.isPlain else { return escaped }
        var html = escaped
        if attributes.code { html = "<code>\(html)</code>" }
        if attributes.italic { html = "<em>\(html)</em>" }
        if attributes.bold { html = "<strong>\(html)</strong>" }
        if attributes.underline { html = "<u>\(html)</u>" }
        if let link = attributes.link {
            // Not user-visible text, but still user-supplied — escaped rather
            // than trusted to be inert, exactly as `MarkdownToHTML` does it.
            html = "<a href=\"\(MarkdownToHTML.escape(link.absoluteString))\">\(html)</a>"
        }
        return html
    }

    // MARK: - Rebasing spans onto the typed region

    /// The UTF-16 offset at which `needle` begins inside `haystack`, or 0 when
    /// it is empty or (impossibly) absent.
    ///
    /// `needle` here is always `QuotedRegion.split`'s visible half, which is
    /// `haystack`'s leading text with surrounding whitespace trimmed. The first
    /// occurrence is therefore the right one: everything before the true start
    /// is whitespace, and a needle that begins with a non-whitespace character
    /// cannot match inside it.
    private static func utf16Offset(ofFirst needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty,
              let range = haystack.range(of: needle) else { return 0 }
        return range.lowerBound.utf16Offset(in: haystack)
    }

    /// Spans clipped to `[start, start + length)` and re-expressed relative to
    /// `start`. A run that only partly overlaps is kept for the part that does;
    /// one that does not overlap at all is dropped, so formatting inside a
    /// quoted trailer or a signature cannot leak into the typed body's markup.
    private static func rebase(_ spans: [RichBody.Span], start: Int,
                               length: Int) -> [RichBody.Span] {
        spans.compactMap { span in
            let from = max(span.start, start)
            let to = min(span.start + span.length, start + length)
            guard from < to else { return nil }
            return RichBody.Span(start: from - start, length: to - from, kind: span.kind)
        }
    }
}
