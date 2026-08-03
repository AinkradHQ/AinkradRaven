import Foundation

/// Converts the plain-text-first Compose body (Markdown) into a minimal, safe
/// HTML fragment for the `text/html` part of an outgoing `multipart/
/// alternative` message. Parsing is done exclusively by Foundation's
/// `AttributedString(markdown:)` — no hand-rolled Markdown grammar — walking
/// its `presentationIntent` (block structure: paragraphs, lists) and
/// `inlinePresentationIntent`/`link` (bold, italic, code, links) attributes
/// to emit tags.
///
/// SUPPORTED, honestly: paragraphs, bold, italic, inline code, links, and
/// unordered/ordered bullet lists — exactly what `AttributedString(markdown:
/// options: .full)` exposes clean block identity for. Anything else
/// Markdown-ish that Foundation's parser recognizes (block quotes, headers,
/// code blocks, tables, thematic breaks) is NOT specially rendered: its text
/// still comes through (inside whatever paragraph/list structure wraps it),
/// just without a dedicated tag, because this task only asked for the list
/// above and guessing at safe markup for the rest is a good way to introduce
/// exactly the injection risk this exists to avoid.
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
        default:
            // Block quotes, headers, code blocks, tables, thematic breaks —
            // not part of the supported subset. Text still renders; no tag.
            return (nil, nil)
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
