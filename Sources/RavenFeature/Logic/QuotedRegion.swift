import Foundation

/// Separates a composed reply's own newly-typed text from the quoted original
/// beneath it, so the HTML part can render each correctly.
///
/// Why this exists: `ReplyComposer.quoteBody` emits the quoted original as
/// **plain text** (`> `-prefixed lines under an attribution line), and the HTML
/// part then handed that whole string to a Markdown parser. Quoted text is a
/// verbatim record of what somebody else wrote, so reinterpreting it as
/// structure is wrong in general, not just in one case:
///
/// - a quoted `-- ` sigdash is a setext-h2 underline, so the quoted line above
///   it became `<h2>`;
/// - a quoted `---` becomes a thematic break;
/// - a quoted `# text` becomes a heading;
/// - quoted `*text*` becomes emphasis, and underscores in a quoted URL become
///   emphasis mid-word.
///
/// None of that is what the original author wrote. So the quoted region is
/// split off here — the same structured route `Signature.split` already proved
/// — and rendered literally by `MarkdownToHTML`: escaped, with `<br>` line
/// breaks, inside a `<blockquote>`. Only the user's own typed body is Markdown.
///
/// The plain-text part is NOT affected: it keeps its `> ` prefixes exactly as
/// before, because `QuoteTrimmer` (and every recipient's client) depends on
/// that shape.
public enum QuotedRegion {
    public struct Split: Equatable, Sendable {
        /// The user's own newly-typed text. Markdown-rendered.
        public let body: String
        /// The `On … wrote:` line introducing the quote, if there was one.
        /// Rendered literally, as its own paragraph ABOVE the blockquote —
        /// it introduces the quote rather than being part of it, and it carries
        /// an attacker-controlled display name that must not become markup.
        public let attribution: String?
        /// The quoted lines, one leading quote level already stripped, in
        /// order. Nil when the composed text contains no quote at all.
        public let quotedLines: [String]?
    }

    /// Splits at the quote boundary `QuoteTrimmer` identifies — deliberately
    /// the same decision the thread view makes when it collapses a quoted
    /// trailer, so the two can never disagree about where a quote starts.
    public static func split(_ text: String) -> Split {
        let (visible, quoted) = QuoteTrimmer.split(text)
        guard let quoted else { return Split(body: text, attribution: nil, quotedLines: nil) }

        var lines = quoted
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // `QuoteTrimmer`'s pattern is `(?m)^\s*(On .+wrote:|…)`, and that `\s*`
        // can consume the blank line(s) `quoteBody` puts before the
        // attribution — so the trailer it returns may START with those blank
        // lines rather than with the attribution itself. Drop them before
        // looking for the attribution, or it is never found and the whole
        // attribution line ends up inside the blockquote.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }

        var attribution: String?
        if let first = lines.first, QuoteTrimmer.isAttributionLine(first) {
            attribution = first.trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        // Strip quote markers BEFORE trimming the tail: a trailing `> ` line is
        // not blank until its marker is gone, so trimming first would leave an
        // empty quoted line behind.
        var quotedLines = lines.map(stripOneQuoteLevel)
        while let last = quotedLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            quotedLines.removeLast()
        }

        return Split(body: visible, attribution: attribution, quotedLines: quotedLines)
    }

    /// Removes exactly one `> ` (or bare `>`) marker. Deeper markers are left
    /// as literal text: the `<blockquote>` expresses the level this reply added,
    /// and a nested quote's own `>` is part of what the author actually wrote —
    /// which is precisely what a verbatim record should show.
    private static func stripOneQuoteLevel(_ line: String) -> String {
        if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
        if line.hasPrefix(">") { return String(line.dropFirst()) }
        return line
    }
}
