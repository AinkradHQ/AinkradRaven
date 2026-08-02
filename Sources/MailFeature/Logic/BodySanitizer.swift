import Foundation

/// Mail HTML is hostile: scripts, tracking pixels, and layout that fights the
/// HUD theme. The default rendering path is text derived here; the real HTML is
/// shown only behind an explicit "Show original".
public enum BodySanitizer {
    private static let dangerousBlocks = ["script", "style", "iframe", "object", "embed"]

    public static func plainText(fromHTML html: String) -> String {
        var working = html

        // Repeat block removal until stable: a single pass can be defeated by
        // overlapping/nested tag fragments (e.g. `<scr<script>ipt>`) that only
        // become a well-formed `<script>...</script>` after an earlier removal
        // collapses the surrounding markup. Iterating to a fixed point closes
        // that reassembly gap for this class of obfuscation.
        var previous: String
        repeat {
            previous = working
            for tag in dangerousBlocks {
                working = removeBlocks(named: tag, in: working)
                working = removeUnclosed(named: tag, in: working)
            }
        } while working != previous

        // Strip event handler attributes (onerror=, onclick=, ...) before tags
        // are removed, so their JS payload never survives as bare text.
        working = removeEventHandlerAttributes(working)

        // Neutralize javascript: URLs in href/src so they don't leak into the
        // plain text once tags are stripped.
        working = working.replacingOccurrences(
            of: "(?i)(href|src)\\s*=\\s*[\"']\\s*javascript:[^\"']*[\"']",
            with: "", options: .regularExpression)

        working = working.replacingOccurrences(
            of: "<br\\s*/?>|</p>|</div>|</tr>", with: "\n",
            options: [.regularExpression, .caseInsensitive])

        // Decode entities and strip tag-shaped text to a fixed point. Decoding
        // BEFORE the final strip (not after, as a naive single pass would do)
        // matters: entity-encoded markup like `&lt;script&gt;` must not survive
        // stripping and then reconstitute into a literal "<script>" in the
        // output once decoded — that string would be live if any consumer ever
        // re-rendered it. Iterating covers double-encoding
        // (`&amp;lt;script&amp;gt;`) regardless of the (unordered) entity-table
        // iteration order. Capped so a pathological input can't loop unbounded;
        // in practice this converges in 2-3 passes.
        var decodeIterations = 0
        repeat {
            previous = working
            working = decodeEntities(working)
            working = stripTagShaped(working)
            decodeIterations += 1
        } while working != previous && decodeIterations < 8

        return working
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only matches genuinely tag-shaped text (`<tag ...>`, `</tag>`, `<!...>`) —
    /// deliberately narrower than `<[^>]+>` so that legitimate prose using bare
    /// `<`/`>` as comparison operators (e.g. "5 &lt; 6 and 7 &gt; 3", which
    /// decodes to "5 < 6 and 7 > 3") is left intact instead of being swallowed
    /// as if it were a tag.
    private static let tagShapedPattern = "<\\/?[A-Za-z!][^<>]*>"

    private static func stripTagShaped(_ html: String) -> String {
        html.replacingOccurrences(
            of: tagShapedPattern, with: "", options: .regularExpression)
    }

    /// Every http(s) (including protocol-relative `//host/...`, which loads
    /// over https and is a common tracking-pixel disguise) image source.
    /// `cid:` inline parts are excluded — they come from the message itself
    /// and leak nothing. Matches quoted (single/double) and bare/unquoted
    /// attribute values, since hostile or malformed mail HTML routinely omits
    /// quotes.
    public static func remoteImageURLs(inHTML html: String) -> [String] {
        let pattern = "<img\\b[^>]*?\\bsrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            for group in 1...3 {
                guard let found = Range(match.range(at: group), in: html) else { continue }
                let url = String(html[found])
                return isRemote(url) ? url : nil
            }
            return nil
        }
    }

    private static func isRemote(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    private static func removeBlocks(named tag: String, in html: String) -> String {
        html.replacingOccurrences(
            of: "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>", with: "",
            options: [.regularExpression, .caseInsensitive])
    }

    /// Removes an opening tag with no matching close (e.g. a truncated or
    /// malformed `<script>` with no `</script>`), taking everything to the end
    /// of the document with it so the payload can't leak as text.
    private static func removeUnclosed(named tag: String, in html: String) -> String {
        guard html.range(
            of: "<\\s*/\\s*\(tag)\\s*>", options: [.regularExpression, .caseInsensitive]) == nil
        else { return html }
        return html.replacingOccurrences(
            of: "<\\s*\(tag)\\b[^>]*>[\\s\\S]*$", with: "",
            options: [.regularExpression, .caseInsensitive])
    }

    private static func removeEventHandlerAttributes(_ html: String) -> String {
        html.replacingOccurrences(
            of: "(?i)\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        return entities.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}
