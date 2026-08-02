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
        working = working.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(working)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every http(s) image source. `cid:` inline parts are excluded — they come
    /// from the message itself and leak nothing.
    public static func remoteImageURLs(inHTML html: String) -> [String] {
        let pattern = "<img[^>]+src\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let found = Range(match.range(at: 1), in: html) else { return nil }
            let url = String(html[found])
            return url.lowercased().hasPrefix("http") ? url : nil
        }
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
