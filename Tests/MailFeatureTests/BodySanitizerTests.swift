import Testing
@testable import MailFeature

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
}
