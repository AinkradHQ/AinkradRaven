import Foundation

/// Mail HTML is hostile: scripts, tracking pixels, and layout that fights the
/// HUD theme. The default rendering path is text derived here; the real HTML is
/// shown only behind an explicit "Show original".
public enum BodySanitizer {
    private static let dangerousBlocks = ["script", "style", "iframe", "object", "embed"]

    /// Cap on the decode-then-clean fixed-point loop below. Chosen generously
    /// above the 2-3 passes real inputs (including double-encoding) converge
    /// in, while still bounding worst-case cost.
    private static let maxCleaningIterations = 12

    public static func plainText(fromHTML html: String) -> String {
        var working = html
        var previous = ""
        var iterations = 0

        // The whole cleaning pipeline runs to a fixed point AFTER decoding on
        // every iteration, not once before it. Two rounds of regex
        // whack-a-mole (entity decoding running once, after stripping; then
        // event-handler removal running once, before decoding) both failed
        // for the same underlying reason: any step can *reveal* markup that
        // the steps before it were supposed to have already cleaned. Decoding
        // first each iteration, then re-running block removal, event-handler
        // stripping, and tag stripping against the newly-decoded text, means
        // nothing revealed by decoding gets a free pass — it's cleaned again
        // on the same iteration it appears, and the loop repeats until no
        // step changes anything.
        while working != previous && iterations < maxCleaningIterations {
            previous = working
            working = decodeEntities(working)
            for tag in dangerousBlocks {
                working = removeBlocks(named: tag, in: working)
                working = removeUnclosed(named: tag, in: working)
            }
            working = removeEventHandlerAttributes(working)
            working = working.replacingOccurrences(
                of: "(?i)(href|src)\\s*=\\s*[\"']\\s*javascript:[^\"']*[\"']",
                with: "", options: .regularExpression)
            working = working.replacingOccurrences(
                of: "<br\\s*/?>|</p>|</div>|</tr>", with: "\n",
                options: [.regularExpression, .caseInsensitive])
            working = stripTagShaped(working)
            iterations += 1
        }

        // Hitting the cap while the string is still changing means the input
        // is adversarial enough that the pipeline above cannot be trusted to
        // have converged. Rather than return a partially-cleaned string, fall
        // back to the most aggressive option: drop every `<`/`>` from what's
        // left, so nothing tag-shaped can possibly remain.
        if working != previous {
            working = working.replacingOccurrences(of: "[<>]", with: "", options: .regularExpression)
        }

        // Final, unconditional safety net. This is the actual security
        // boundary — everything above it is best-effort cleanup for output
        // quality, not the guarantee itself. Regardless of what the pipeline
        // above missed (a new bypass, an ordering hole, an input neither of
        // us has thought of), any `<` immediately followed by a letter, `/`,
        // `!`, or `?` is the only shape that can begin an HTML tag, so it is
        // dropped here unconditionally. A `<` followed by anything else
        // (space, digit, end-of-string) is ordinary prose — e.g. "5 < 6" —
        // and is left untouched so it still reads naturally.
        working = neutralizeResidualTagOpeners(working)

        return working
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only matches genuinely tag-shaped text (`<tag ...>`, `</tag>`, `<!...>`) —
    /// deliberately narrower than `<[^>]+>` so that legitimate prose using bare
    /// `<`/`>` as comparison operators (e.g. "5 &lt; 6 and 7 &gt; 3", which
    /// decodes to "5 < 6 and 7 > 3") is left intact instead of being swallowed
    /// as if it were a tag. This is an output-quality optimization on top of
    /// the pipeline, not the security boundary — see `neutralizeResidualTagOpeners`.
    private static let tagShapedPattern = "<\\/?[A-Za-z!][^<>]*>"

    private static func stripTagShaped(_ html: String) -> String {
        html.replacingOccurrences(
            of: tagShapedPattern, with: "", options: .regularExpression)
    }

    /// The invariant this sanitizer actually guarantees: no `<` in the output
    /// is immediately followed by a letter, `/`, `!`, or `?` — the only
    /// characters that can begin an HTML tag (`<tag`, `</tag`, `<!--`,
    /// `<?xml`). Matched `<` characters are dropped (not replaced with `&lt;`
    /// text) so the output never contains an entity that a future change
    /// might accidentally decode again. A `<` followed by whitespace, a
    /// digit, or end-of-string is left in place since it cannot begin a tag.
    private static func neutralizeResidualTagOpeners(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<(?=[A-Za-z/!?])", with: "", options: .regularExpression)
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
