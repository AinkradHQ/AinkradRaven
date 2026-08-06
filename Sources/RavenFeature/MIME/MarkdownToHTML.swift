import Foundation

/// Converts the plain-text-first Compose body (Markdown) into a minimal, safe
/// HTML fragment for the `text/html` part of an outgoing `multipart/
/// alternative` message. Parsing is done exclusively by Foundation's
/// `AttributedString(markdown:)` — no hand-rolled Markdown grammar — walking
/// its `presentationIntent` (block structure: paragraphs, lists) and
/// `inlinePresentationIntent`/`link` (bold, italic, code, links) attributes
/// to emit tags.
///
/// SUPPORTED: paragraphs, bold, italic, inline code, links, unordered/ordered
/// bullet lists, **block quotes** (nested to any depth), headers, code blocks,
/// thematic breaks, and tables.
///
/// Every block kind is now mapped explicitly. It used to fall through a
/// `default: return (nil, nil)` arm that emitted neither a tag nor a
/// separator, and that arm cost two critical defects at once:
///
/// 1. `ReplyComposer.quoteBody` produces `> line one\n> line two`, which
///    parses as a `blockQuote` — so the HTML part of every reply rendered
///    `<p>line one line two</p>`: quote markers stripped, lines merged, and
///    the original author's words presented as the sender's own. Gmail
///    displays `text/html`, so that is what recipients actually saw.
///    (A reply's quoted trailer no longer reaches this parser at all — see
///    `renderComposed` and `QuotedRegion` — but `blockQuote` is still mapped,
///    because a user may legitimately type a `>` quote in their own body.)
/// 2. The `-- ` sigdash is a valid setext-h2 underline, so the last line of
///    every signed body became a `header` block and was dropped outright.
///    (`Signature.split` now keeps the sigdash away from the parser entirely;
///    headers are mapped regardless, because a user may legitimately type
///    one.)
///
/// The `@unknown default` arm that remains — reachable only if Foundation
/// gains a block kind — emits a paragraph rather than nothing, so an
/// unrecognised block still costs a wrapper tag, never its text.
///
/// Structural tags are emitted from this fixed table only; no attacker-
/// controlled text ever becomes a tag or an attribute name.
///
/// Every run of literal text is escaped (`&`, `<`, `>`) before being written,
/// so Markdown source containing literal HTML (e.g. a user typing `<script>`)
/// is rendered as visible text, never live markup.
enum MarkdownToHTML {
    static func render(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard !markdown.isEmpty,
              let attributed = try? AttributedString(markdown: markdown, options: options) else {
            // Parsing failure (or empty input) still must not lose or corrupt
            // the text — fall back to a single escaped paragraph.
            return markdown.isEmpty ? "" : "<p>\(escape(markdown))</p>"
        }
        return renderBlocks(attributed)
    }

    /// Renders a *composed* body — what `ComposeSurface`/`ReplyComposer` typed
    /// and `SendAttempt` then appended a signature to — by first taking it
    /// APART, so that only the user's own newly-typed text is ever handed to
    /// the Markdown parser.
    ///
    /// Two regions must not be parsed as Markdown, for the same underlying
    /// reason — they are records of text, not authored Markdown, and letting a
    /// parser find structure in them rewrites what someone actually wrote:
    ///
    /// - **The signature.** `--` under a line of text is a valid setext h2
    ///   underline, so the concatenated string turned the body's last line into
    ///   a heading and consumed the `-- ` separator recipients' clients use to
    ///   trim a signature.
    /// - **The quoted original.** `ReplyComposer.quoteBody` emits it as plain
    ///   text, so a quoted `-- `, `---`, `# heading`, `*bullet*`, or an
    ///   underscore inside a quoted URL all became structure in the *sender's*
    ///   reply. See `QuotedRegion`.
    ///
    /// Emission order, which holds when all three regions are present:
    /// **typed body (Markdown) → signature (literal) → quoted original
    /// (literal)**. The signature sits above the quote because it belongs to
    /// the new message, not to the thing being quoted. The plain-text part is
    /// untouched by any of this and keeps its own order and its `> ` prefixes.
    static func renderComposed(_ composed: String) -> String {
        // Signature first: `SendAttempt` appends it last, so it is the outermost
        // layer. Its `\n-- \n` cannot collide with a quoted sigdash, which
        // arrives as `\n> -- \n`.
        let (withoutSignature, signature) = Signature.split(composed)
        let quote = QuotedRegion.split(withoutSignature)

        var html = render(quote.body)
        if let signature {
            html += "<div class=\"sig\">-- <br>\(literalLines(signature))</div>"
        }
        if let quotedLines = quote.quotedLines {
            if let attribution = quote.attribution {
                html += "<p>\(escape(attribution))</p>"
            }
            html += "<blockquote>\(literalLines(quotedLines.joined(separator: "\n")))</blockquote>"
        }
        return html
    }

    /// Escaped text with its line breaks preserved as `<br>` — for content
    /// that must render as typed, with no Markdown interpretation at all.
    private static func literalLines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { escape(String($0)) }
            .joined(separator: "<br>")
    }

    // MARK: Escaping

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: Block walking

    /// One entry in the currently-open tag stack, outermost first.
    private struct OpenBlock {
        let identity: Int
        let closingTag: String
    }

    private static func renderBlocks(_ attributed: AttributedString) -> String {
        var html = ""
        var stack: [OpenBlock] = []

        for run in attributed.runs {
            // Outermost-to-innermost; `PresentationIntent.components` comes
            // back innermost-first (paragraph, then its container(s)).
            let path = (run.presentationIntent?.components ?? []).reversed()
            let identities = path.map(\.identity)

            // Close any open block whose identity is no longer a prefix of
            // this run's path, innermost (end of stack) first.
            var commonPrefix = 0
            while commonPrefix < stack.count && commonPrefix < identities.count
                    && stack[commonPrefix].identity == identities[commonPrefix] {
                commonPrefix += 1
            }
            while stack.count > commonPrefix {
                html += stack.removeLast().closingTag
            }

            // Open whatever is new for this run, outer to inner.
            for component in path.dropFirst(commonPrefix) {
                let (openTag, closeTag) = tags(for: component.kind, isInsideListItem: isListItem(stack))
                if let openTag {
                    html += openTag
                    stack.append(OpenBlock(identity: component.identity, closingTag: closeTag ?? ""))
                } else {
                    // No dedicated tag (see the type's documentation) — still
                    // track identity so nested content closes correctly.
                    stack.append(OpenBlock(identity: component.identity, closingTag: ""))
                }
            }

            html += renderInline(attributed[run.range], inline: run.inlinePresentationIntent,
                                 link: run.link)
        }
        while !stack.isEmpty { html += stack.removeLast().closingTag }
        return html
    }

    private static func isListItem(_ stack: [OpenBlock]) -> Bool {
        stack.last?.closingTag == "</li>"
    }

    /// Maps one `PresentationIntent.Kind` to its opening/closing tag. A
    /// `paragraph` directly inside a `listItem` is deliberately left
    /// untagged (`nil`, `nil`) — `<p>` nested straight inside `<li>` is legal
    /// HTML but renders with extra spacing in most mail clients for a single
    /// line of list text, so the bullet's own `<li>` already carries it.
    ///
    /// Every other kind maps to real markup. Nesting needs no special case:
    /// `renderBlocks` opens each component of the intent path in order, so a
    /// quote inside a quote yields nested `<blockquote>` elements and a
    /// paragraph inside a quote keeps its own `<p>`.
    private static func tags(for kind: PresentationIntent.Kind,
                             isInsideListItem: Bool) -> (String?, String?) {
        switch kind {
        case .paragraph:
            return isInsideListItem ? (nil, nil) : ("<p>", "</p>")
        case .unorderedList:
            return ("<ul>", "</ul>")
        case .orderedList:
            return ("<ol>", "</ol>")
        case .listItem:
            return ("<li>", "</li>")
        case .blockQuote:
            return ("<blockquote>", "</blockquote>")
        case .header(let level):
            // Markdown allows h1–h6; clamp rather than trusting the parser to
            // never hand back something outside that range, since the level
            // is interpolated into a tag name.
            let clamped = min(max(level, 1), 6)
            return ("<h\(clamped)>", "</h\(clamped)>")
        case .codeBlock:
            // The language hint is attacker-controlled text, so it is NOT
            // emitted as a class; the block's content still renders verbatim
            // (and escaped) inside `<pre><code>`.
            return ("<pre><code>", "</code></pre>")
        case .thematicBreak:
            // A void element: opened, never closed. Carries no text of its own.
            return ("<hr>", "")
        case .table:
            return ("<table>", "</table>")
        case .tableHeaderRow:
            return ("<tr>", "</tr>")
        case .tableRow:
            return ("<tr>", "</tr>")
        case .tableCell:
            return ("<td>", "</td>")
        @unknown default:
            // A block kind Foundation gained after this was written. Emit a
            // paragraph rather than nothing: a wrong-but-present wrapper is
            // recoverable, silently dropped text is not — which is exactly
            // how the block-quote and sigdash defects shipped.
            return ("<p>", "</p>")
        }
    }

    // MARK: Inline formatting

    private static func renderInline(_ substring: AttributedSubstring,
                                     inline: InlinePresentationIntent?,
                                     link: URL?) -> String {
        let text = escape(String(substring.characters))
        guard !text.isEmpty else { return "" }
        var rendered = text
        if let inline, inline.contains(.code) {
            rendered = "<code>\(rendered)</code>"
        }
        if let inline, inline.contains(.emphasized) {
            rendered = "<em>\(rendered)</em>"
        }
        if let inline, inline.contains(.stronglyEmphasized) {
            rendered = "<strong>\(rendered)</strong>"
        }
        if let link {
            // The link target is not user-visible text but is still
            // attacker-controlled (a Markdown link's URL); escape it too
            // rather than trusting `URL`'s string form is inert.
            rendered = "<a href=\"\(escape(link.absoluteString))\">\(rendered)</a>"
        }
        return rendered
    }
}
