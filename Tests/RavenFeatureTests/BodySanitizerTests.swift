import Foundation
import Testing
@testable import RavenFeature

@Suite("Body sanitizer")
struct BodySanitizerTests {
    @Test("script contents never survive into the rendered text")
    func stripsScripts() {
        let html = "<p>Hello</p><script>alert('x')</script><p>Bye</p>"
        let text = BodySanitizer.plainText(fromHTML: html)
        #expect(text.contains("alert") == false)
        #expect(text.contains("Hello"))
        #expect(text.contains("Bye"))
    }

    @Test("style blocks are dropped rather than rendered as text")
    func stripsStyle() {
        let text = BodySanitizer.plainText(fromHTML: "<style>p{color:red}</style><p>Hi</p>")
        #expect(text.contains("color:red") == false)
        #expect(text.contains("Hi"))
    }

    @Test("remote images are reported so the UI can block them")
    func findsRemoteImages() {
        let html = "<img src=\"https://tracker.example/pixel.gif\"><img src=\"cid:inline\">"
        let urls = BodySanitizer.remoteImageURLs(inHTML: html)
        #expect(urls == ["https://tracker.example/pixel.gif"])
    }

    @Test("entities are decoded")
    func decodesEntities() {
        #expect(BodySanitizer.plainText(fromHTML: "<p>Tom &amp; Jerry</p>").contains("Tom & Jerry"))
    }

    // MARK: - Adversarial cases

    @Test("script with attribute or unusual casing/whitespace is stripped")
    func stripsScriptWithAttributesAndCasing() {
        let html = "<p>A</p><SCRIPT >alert('x')</SCRIPT><p>B</p>" +
            "<script type=\"text/javascript\">alert('y')</script><p>C</p>"
        let text = BodySanitizer.plainText(fromHTML: html)
        #expect(text.contains("alert") == false)
        #expect(text.contains("A"))
        #expect(text.contains("B"))
        #expect(text.contains("C"))
    }

    @Test("unclosed script tag does not leak its contents")
    func unclosedScriptDoesNotLeak() {
        let html = "<p>Hello</p><script>alert('x'); var y = '<p>Bye</p>';"
        let text = BodySanitizer.plainText(fromHTML: html)
        #expect(text.contains("alert") == false)
        #expect(text.contains("Hello"))
    }

    @Test("event handler attributes do not survive into the output text")
    func eventHandlersStripped() {
        let html = "<img src=\"cid:x\" onerror=\"alert(1)\"><a href=\"#\" onclick=\"steal()\">click</a>"
        let text = BodySanitizer.plainText(fromHTML: html)
        #expect(text.contains("alert") == false)
        #expect(text.contains("steal") == false)
    }

    @Test("javascript: URL is not returned as a remote image and leaves no clickable artifact")
    func javascriptURLNotSurfaced() {
        let html = "<img src=\"javascript:alert(1)\"><a href=\"javascript:alert(2)\">link</a>"
        let urls = BodySanitizer.remoteImageURLs(inHTML: html)
        #expect(urls.isEmpty)
        let text = BodySanitizer.plainText(fromHTML: html)
        #expect(text.contains("javascript:") == false)
    }

    @Test("obfuscated nested tag does not reassemble into a live script tag")
    func obfuscatedNestedTagDoesNotReassemble() {
        let html = "<p>Hi</p><scr<script>ipt>alert('x')</script><p>Bye</p>"
        let text = BodySanitizer.plainText(fromHTML: html)
        #expect(text.contains("<script>") == false)
        #expect(text.contains("alert") == false)
    }

    // MARK: - Reviewer findings (order-of-operations and detection bypasses)

    @Test("entity-encoded script tags do not reconstitute after decoding")
    func encodedScriptDoesNotReconstitute() {
        let text = BodySanitizer.plainText(fromHTML: "&lt;script&gt;alert(1)&lt;/script&gt;")
        #expect(text.contains("<script>") == false)
        #expect(text.contains("</script>") == false)
    }

    @Test("double-encoded script tags do not reconstitute after decoding")
    func doubleEncodedScriptDoesNotReconstitute() {
        let text = BodySanitizer.plainText(fromHTML: "&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;")
        #expect(text.contains("<script>") == false)
        #expect(text.contains("</script>") == false)
    }

    @Test("a real tag and an entity-encoded tag together both fail to survive as tags")
    func mixedRealAndEncodedTagsBothStripped() {
        let html = "<p>Hi</p>&lt;script&gt;alert(1)&lt;/script&gt;<p>Bye</p>"
        let text = BodySanitizer.plainText(fromHTML: html)
        #expect(text.contains("<script>") == false)
        #expect(text.contains("Hi"))
        #expect(text.contains("Bye"))
    }

    @Test("legitimate prose using bare < and > as comparisons reads naturally")
    func proseWithComparisonOperatorsIsPreserved() {
        let text = BodySanitizer.plainText(fromHTML: "<p>5 &lt; 6 and 7 &gt; 3</p>")
        #expect(text.contains("5 < 6 and 7 > 3"))
    }

    @Test("protocol-relative image sources are detected as remote")
    func protocolRelativeImageIsRemote() {
        let html = "<img src=\"//tracker.example/pixel.gif\">"
        let urls = BodySanitizer.remoteImageURLs(inHTML: html)
        #expect(urls == ["//tracker.example/pixel.gif"])
    }

    @Test("unquoted image src attributes are detected across quoting styles")
    func unquotedAndQuotedImageSrcAreAllDetected() {
        let html = "<img src=http://a.example/x.gif>" +
            "<img src=\"https://b.example/y.gif\">" +
            "<img src='https://c.example/z.gif'>"
        let urls = BodySanitizer.remoteImageURLs(inHTML: html)
        #expect(urls == [
            "http://a.example/x.gif",
            "https://b.example/y.gif",
            "https://c.example/z.gif",
        ])
    }

    @Test("deep nesting and large input stay cheap after the decode/strip loop")
    func costProfileStaysBounded() {
        let deepNest = String(repeating: "<scr", count: 2000)
            + "<script>" + String(repeating: "ipt>", count: 2000) + "alert(1)</script>"
        let start1 = Date()
        _ = BodySanitizer.plainText(fromHTML: deepNest)
        let deepNestElapsed = Date().timeIntervalSince(start1)
        #expect(deepNestElapsed < 2.0)

        let oneMB = String(
            repeating: "<p>Hello world, this is prose &amp; more &lt;text&gt;.</p>", count: 20000)
        let start2 = Date()
        _ = BodySanitizer.plainText(fromHTML: oneMB)
        let oneMBElapsed = Date().timeIntervalSince(start2)
        #expect(oneMBElapsed < 2.0)
    }

    // MARK: - Round 2 reviewer findings: decode-order hole in the pre-decode
    // event-handler stripping regex, closed by restructuring the pipeline to
    // run to a fixed point AFTER decoding, plus an unconditional final sweep.

    private static func containsTagOpener(_ text: String) -> Bool {
        text.range(of: "<[A-Za-z/!?]", options: .regularExpression) != nil
    }

    @Test("harness case 1: encoded onerror with an entity-encoded terminator does not leave a live-looking fragment")
    func harnessCase1EncodedOnerrorTerminator() {
        let text = BodySanitizer.plainText(fromHTML: "<b>hi</b>&lt;img src=x onerror=alert(1)&gt;")
        #expect(BodySanitizerTests.containsTagOpener(text) == false)
        #expect(text.contains("hi"))
    }

    @Test("harness case 2: encoded script with an encoded onerror terminator does not leave a live-looking fragment")
    func harnessCase2EncodedScriptOnerrorTerminator() {
        let text = BodySanitizer.plainText(
            fromHTML: "&lt;script src=x onerror=y&gt;alert(1)&lt;/script&gt;")
        #expect(BodySanitizerTests.containsTagOpener(text) == false)
    }

    @Test("double-encoded tag with no other content does not reconstitute")
    func doubleEncodedBareTagDoesNotReconstitute() {
        let text = BodySanitizer.plainText(fromHTML: "&amp;lt;script&amp;gt;")
        #expect(BodySanitizerTests.containsTagOpener(text) == false)
    }

    @Test("the nested-reassembly fragment does not leak a bare '<' before a letter")
    func nestedReassemblyFragmentDoesNotLeak() {
        let text = BodySanitizer.plainText(fromHTML: "<scr<script>ipt>alert(1)</script>")
        #expect(BodySanitizerTests.containsTagOpener(text) == false)
    }

    @Test("prose preservation: decoded comparisons read naturally, unencoded ones are untouched")
    func prosePreservationExactStrings() {
        #expect(BodySanitizer.plainText(fromHTML: "5 &lt; 6 and 7 &gt; 3") == "5 < 6 and 7 > 3")
        #expect(BodySanitizer.plainText(fromHTML: "a < b") == "a < b")
    }

    /// Property-style check over the whole adversarial corpus: for every input
    /// this suite has ever thrown at the sanitizer, the output must contain no
    /// occurrence of `<` immediately followed by a letter, `/`, `!`, or `?` —
    /// the only shapes that can begin an HTML tag. This is the actual
    /// guarantee (enforced by `neutralizeResidualTagOpeners`); everything else
    /// in the pipeline is best-effort cleanup on top of it. Written as a loop
    /// so future adversarial cases are cheap to add to `corpus`.
    @Test("no output over the adversarial corpus contains a tag-shaped '<'")
    func noTagOpenerSurvivesAcrossTheCorpus() {
        let corpus = [
            "<p>Hello</p><script>alert('x')</script><p>Bye</p>",
            "<style>p{color:red}</style><p>Hi</p>",
            "<p>Tom &amp; Jerry</p>",
            "<p>A</p><SCRIPT >alert('x')</SCRIPT><p>B</p><script type=\"text/javascript\">alert('y')</script><p>C</p>",
            "<p>Hello</p><script>alert('x'); var y = '<p>Bye</p>';",
            "<img src=\"cid:x\" onerror=\"alert(1)\"><a href=\"#\" onclick=\"steal()\">click</a>",
            "<img src=\"javascript:alert(1)\"><a href=\"javascript:alert(2)\">link</a>",
            "<p>Hi</p><scr<script>ipt>alert('x')</script><p>Bye</p>",
            "&lt;script&gt;alert(1)&lt;/script&gt;",
            "&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;",
            "<p>Hi</p>&lt;script&gt;alert(1)&lt;/script&gt;<p>Bye</p>",
            "<p>5 &lt; 6 and 7 &gt; 3</p>",
            "<b>hi</b>&lt;img src=x onerror=alert(1)&gt;",
            "&lt;script src=x onerror=y&gt;alert(1)&lt;/script&gt;",
            "&amp;lt;script&amp;gt;",
            "<scr<script>ipt>alert(1)</script>",
            "5 &lt; 6 and 7 &gt; 3",
            "a < b",
        ]
        for input in corpus {
            let output = BodySanitizer.plainText(fromHTML: input)
            #expect(BodySanitizerTests.containsTagOpener(output) == false, "leaked a tag opener for input: \(input)")
        }
    }
}
