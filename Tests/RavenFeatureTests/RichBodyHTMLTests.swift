import Testing
import Foundation
@testable import RavenFeature

/// The renderer half of Task 21: what `RichBodyHTML` emits for a given set of
/// spans, asserted as **literal strings**.
///
/// Literal rather than "contains a `<strong>`" on purpose. The whole reason
/// `NSAttributedString`'s HTML writer was rejected is that its output cannot be
/// pinned in a test; a renderer written to replace it that is only checked for
/// substrings gives back exactly the property it was chosen for.
@Suite("RichBodyHTML — the restricted tag table")
struct RichBodyHTMLTests {
    private func html(_ text: String, _ spans: [RichBody.Span]) -> String {
        RichBodyHTML.renderComposed(RichBody(text: text, spans: spans))
    }

    private func span(_ start: Int, _ length: Int, _ kind: RichBody.Kind) -> RichBody.Span {
        RichBody.Span(start: start, length: length, kind: kind)
    }

    @Test("an unformatted line is one paragraph and nothing else")
    func plainParagraph() {
        #expect(html("Hello there", []) == "<p>Hello there</p>")
    }

    @Test("empty text renders nothing at all")
    func emptyRendersNothing() {
        #expect(html("", []) == "")
    }

    @Test("each inline kind emits its own tag, and only over its own run")
    func inlineKinds() {
        #expect(html("Hello there", [span(0, 5, .bold)])
            == "<p><strong>Hello</strong> there</p>")
        #expect(html("Hello there", [span(6, 5, .italic)])
            == "<p>Hello <em>there</em></p>")
        #expect(html("Hello there", [span(0, 5, .underline)])
            == "<p><u>Hello</u> there</p>")
        #expect(html("Hello there", [span(6, 5, .code)])
            == "<p>Hello <code>there</code></p>")
    }

    @Test("a link is an anchor whose href is escaped, not trusted")
    func links() throws {
        let url = try #require(URL(string: "https://example.test/a?x=1&y=2"))
        #expect(html("See docs", [span(4, 4, .link(url))])
            == "<p>See <a href=\"https://example.test/a?x=1&amp;y=2\">docs</a></p>")
    }

    /// Overlapping runs are the ordinary case — the editor imposes no nesting —
    /// so the emission order has to be fixed, and this is where it is pinned.
    @Test("overlapping runs nest in a fixed order and split at every boundary")
    func overlappingRuns() {
        #expect(html("abcd", [span(0, 3, .bold), span(2, 2, .italic)])
            == "<p><strong>ab</strong><strong><em>c</em></strong><em>d</em></p>")
    }

    /// Not a restatement of the line above: this is the one property that keeps
    /// the two renderers from spelling the same visible formatting differently.
    /// `MarkdownToHTML` is called on Markdown source, this renderer on spans,
    /// and the bytes must match.
    @Test("a bold-italic run is spelled identically by both renderers")
    func bothRenderersAgreeOnNesting() {
        #expect(html("word", [span(0, 4, .bold), span(0, 4, .italic)])
            == MarkdownToHTML.render("***word***"))
        #expect(html("word", [span(0, 4, .bold), span(0, 4, .italic)])
            == "<p><strong><em>word</em></strong></p>")
    }

    @Test("literal text is escaped, so typed markup renders as text")
    func escaping() {
        #expect(html("<script>a & b</script>", [])
            == "<p>&lt;script&gt;a &amp; b&lt;/script&gt;</p>")
    }

    /// Line breaks are preserved because the user pressed Return. This is a
    /// deliberate difference from the Markdown path, where a single newline is a
    /// soft break the parser folds away.
    @Test("a newline is a <br> and a blank line starts a new paragraph")
    func lineBreaksAndParagraphs() {
        #expect(html("one\ntwo\n\nthree", []) == "<p>one<br>two</p><p>three</p>")
    }

    @Test("CRLF and a bare CR break lines without shifting any span")
    func carriageReturnsDoNotShiftSpans() {
        // Normalising the line endings first would rewrite the very string the
        // offsets are measured against: "two" starts at UTF-16 offset 5 only
        // while the CRLF is still two code units.
        #expect(html("one\r\ntwo", [span(5, 3, .bold)])
            == "<p>one<br><strong>two</strong></p>")
        #expect(html("one\rtwo", [span(4, 3, .bold)])
            == "<p>one<br><strong>two</strong></p>")
    }

    @Test("adjacent bullet lines become one list; a blank line ends it")
    func bulletLists() {
        #expect(html("Milk\nEggs", [span(0, 4, .bulletItem), span(5, 4, .bulletItem)])
            == "<ul><li>Milk</li><li>Eggs</li></ul>")
        #expect(html("Milk\n\nAfter", [span(0, 4, .bulletItem)])
            == "<ul><li>Milk</li></ul><p>After</p>")
    }

    @Test("numbered lines become an ordered list, not an unordered one")
    func numberedLists() {
        #expect(html("One\nTwo", [span(0, 3, .numberItem), span(4, 3, .numberItem)])
            == "<ol><li>One</li><li>Two</li></ol>")
    }

    @Test("a block quote wraps its paragraphs and keeps inline formatting inside")
    func blockquotes() {
        #expect(html("Quoted line", [span(0, 11, .blockquote), span(0, 6, .bold)])
            == "<blockquote><p><strong>Quoted</strong> line</p></blockquote>")
    }

    @Test("a list and a quote next to each other stay separate elements")
    func adjacentBlocksDoNotMerge() {
        #expect(html("Item\nSaid", [span(0, 4, .bulletItem), span(5, 4, .blockquote)])
            == "<ul><li>Item</li></ul><blockquote><p>Said</p></blockquote>")
    }

    /// The tag table is the security boundary, so it is asserted as a table: no
    /// `<style>`, no `style=`, no `class=` outside the sigdash wrapper, no font
    /// or colour. A widening slipped in later shows up here.
    ///
    /// The fixture exercises **every** kind the renderer can emit, ordered list
    /// included — a table-closure test whose fixture never reaches `<ol>` would
    /// not notice a widening that only affected ordered lists, however correct
    /// its set comparison looked.
    @Test("nothing outside the fixed tag table is ever emitted")
    func tagTableIsClosed() throws {
        let url = try #require(URL(string: "https://example.test"))
        let rendered = html(
            "Head\nMilk\nEggs\nOne\nQuoted\nplain\n-- \nBest,\nA",
            [span(0, 4, .bold), span(0, 4, .underline), span(5, 4, .bulletItem),
             span(10, 4, .bulletItem), span(15, 3, .numberItem), span(19, 6, .blockquote),
             span(26, 5, .link(url)), span(26, 5, .code), span(26, 5, .italic)])
        let tags = Set(
            rendered.components(separatedBy: "<").dropFirst()
                .map { $0.prefix(while: { $0 != ">" && $0 != " " }) }
                .map(String.init))
        #expect(tags == ["p", "/p", "br", "strong", "/strong", "em", "/em", "u", "/u",
                         "code", "/code", "a", "/a", "ul", "/ul", "ol", "/ol",
                         "li", "/li", "blockquote", "/blockquote", "div", "/div"])
        #expect(rendered.contains("style") == false)
        #expect(rendered.contains("font") == false)
        #expect(rendered.contains("class=") == true)   // only the sigdash wrapper
        #expect(rendered.components(separatedBy: "class=").count - 1 == 1)
    }

    // MARK: - The shared splitters

    @Test("the signature is split off and rendered literally, below the typed body")
    func signatureIsLiteralAndLast() {
        #expect(html("Hello there\n-- \nBest,\nA", [span(0, 5, .bold)])
            == "<p><strong>Hello</strong> there</p>"
                + "<div class=\"sig\">-- <br>Best,<br>A</div>")
    }

    /// `QuoteTrimmer.split` TRIMS the visible half, so the typed region does not
    /// start at offset zero here. A renderer that forgot to rebase would emit
    /// `<strong>M</strong>y` — one character out — which is exactly what this
    /// literal catches.
    @Test("spans are rebased onto the trimmed typed region of a reply")
    func spansSurviveTheQuoteTrim() {
        let composed = "\nMy reply\n\nOn Mon, A wrote:\n> original"
        #expect(html(composed, [span(1, 2, .bold)])
            == "<p><strong>My</strong> reply</p>"
                + "<p>On Mon, A wrote:</p>"
                + "<blockquote>original</blockquote>")
    }

    /// The quoted original is somebody else's words: a verbatim record, never
    /// re-marked-up, whichever renderer produced the message.
    @Test("formatting inside the quoted trailer does not leak into its markup")
    func quotedTrailerIsAlwaysLiteral() {
        let composed = "\nMy reply\n\nOn Mon, A wrote:\n> original"
        let withSpanInQuote = html(composed, [span(28, 8, .bold)])
        #expect(withSpanInQuote == html(composed, []))
        #expect(withSpanInQuote.contains("<strong>") == false)
    }
}
