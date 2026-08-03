import Testing
import Foundation
@testable import RavenFeature

/// The HTML part of every outgoing message. This suite exists because its
/// absence let two critical defects ship: block quotes (i.e. the quoted text in
/// EVERY reply) and the signature separator were both silently dropped by a
/// `default: return (nil, nil)` arm that emitted neither a tag nor a
/// separator. Gmail displays `text/html`, so that output was what recipients
/// actually saw.
@Suite("Markdown to HTML")
struct MarkdownToHTMLTests {

    // MARK: Block quotes — the reply path

    @Test("a block quote becomes a <blockquote>, not merged text")
    func blockQuoteIsTagged() {
        let html = MarkdownToHTML.render("> line one\n> line two")
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("</blockquote>"))
        // The regression: quote markers stripped and the lines merged into an
        // ordinary paragraph, presenting the original author's words as the
        // sender's own.
        #expect(html != "<p>line one line two</p>")
    }

    @Test("a real ReplyComposer quote body keeps the quoted text inside a blockquote and the reply outside it")
    func replyQuoteRendersAsQuotedHTML() {
        let quoted = ReplyComposer.quoteBody(
            mode: .reply, message: Self.quotedMessage,
            bodyText: "quoted line\nsecond quoted line")
        let html = MarkdownToHTML.renderComposed("This is a reply." + quoted)

        // The reply itself is outside the quote…
        let quoteStart = html.range(of: "<blockquote>")
        #expect(quoteStart != nil)
        if let quoteStart {
            let beforeQuote = String(html[html.startIndex..<quoteStart.lowerBound])
            #expect(beforeQuote.contains("This is a reply."))
            #expect(beforeQuote.contains("quoted line") == false)
        }
        // …and both quoted lines are inside it, still present.
        #expect(html.contains("quoted line"))
        #expect(html.contains("second quoted line"))
        #expect(html.contains("wrote:"))
    }

    // MARK: The quoted region is LITERAL — never Markdown

    static let quotedMessage = MailMessage(
        id: "m1", threadID: "t1", rfc822MessageID: "<a@b>",
        from: MailAddress(email: "bea@example.com", name: "Bea"),
        subject: "hello", date: Date(timeIntervalSince1970: 1_700_000_000))

    /// Quoted text is a verbatim record of what somebody else wrote. Anything
    /// in it that merely LOOKS like Markdown must not be reinterpreted as
    /// structure in the sender's reply.
    private static func replyHTML(quoting original: String,
                                  typed: String = "My reply.") -> String {
        MarkdownToHTML.renderComposed(typed + ReplyComposer.quoteBody(
            mode: .reply, message: quotedMessage, bodyText: original))
    }

    @Test("a quoted sigdash no longer turns the quoted line above it into a heading")
    func quotedSigdashIsNotAHeading() {
        let html = Self.replyHTML(quoting: "quoted line\n-- \nأحمد")
        #expect(html.contains("<h2>") == false)
        #expect(html.contains("<h1>") == false)
        // Every part of the original is still there, verbatim.
        #expect(html.contains("quoted line"))
        #expect(html.contains("-- "))
        #expect(html.contains("أحمد"))
        #expect(html.contains("<blockquote>"))
    }

    @Test("a quoted # heading, a quoted --- rule, and quoted *emphasis* all render as literal text")
    func quotedMarkdownIsLiteral() {
        let html = Self.replyHTML(quoting: "# Not a heading\n---\n*not emphasis*\n1. not a list")
        #expect(html.contains("# Not a heading"))
        #expect(html.contains("---"))
        #expect(html.contains("*not emphasis*"))
        #expect(html.contains("1. not a list"))
        // None of it became structure.
        #expect(html.contains("<h1>") == false)
        #expect(html.contains("<hr>") == false)
        #expect(html.contains("<em>") == false)
        #expect(html.contains("<ol>") == false)
        #expect(html.contains("<li>") == false)
    }

    @Test("underscores in a quoted URL do not become emphasis")
    func quotedURLUnderscoresSurvive() {
        let html = Self.replyHTML(quoting: "see https://x.com/a_b_c_d/e")
        #expect(html.contains("https://x.com/a_b_c_d/e"))
        #expect(html.contains("<em>") == false)
    }

    @Test("a quoted <script> is escaped inside the blockquote, not injected")
    func quotedScriptIsEscaped() {
        let html = Self.replyHTML(quoting: "<script>alert('x')</script> & <b>bold</b>")
        #expect(html.contains("<script>") == false)
        #expect(html.contains("<b>") == false)
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&amp;"))
    }

    @Test("an attacker-controlled display name in the attribution line cannot become markup")
    func attributionDisplayNameIsEscaped() {
        let hostile = MailMessage(
            id: "m1", threadID: "t1", rfc822MessageID: "<a@b>",
            from: MailAddress(email: "bea@example.com", name: "<b>Bea</b> *x*"),
            subject: "hello", date: Date(timeIntervalSince1970: 1_700_000_000))
        let html = MarkdownToHTML.renderComposed("Reply." + ReplyComposer.quoteBody(
            mode: .reply, message: hostile, bodyText: "original"))
        #expect(html.contains("&lt;b&gt;Bea&lt;/b&gt;"))
        #expect(html.contains("<b>Bea</b>") == false)
        #expect(html.contains("<em>x</em>") == false)
    }

    @Test("quoted line breaks are preserved as <br>, not merged into one line")
    func quotedLineBreaksPreserved() {
        let html = Self.replyHTML(quoting: "line one\nline two")
        #expect(html.contains("line one<br>line two"))
    }

    // MARK: All three regions together, in order

    @Test("a reply with typed markdown, a signature, and a quote emits exactly one of each, in order")
    func allThreeRegionsInOrder() {
        let composed = "Hello **bold** reply."
            + ReplyComposer.quoteBody(mode: .reply, message: Self.quotedMessage,
                                      bodyText: "original text")
            + Signature.sigdash + "Ahmed\nAinkrad"
        let html = MarkdownToHTML.renderComposed(composed)

        // The typed body is still Markdown-rendered.
        #expect(html.contains("<strong>bold</strong>"))

        // Exactly one of each region.
        #expect(html.components(separatedBy: "<div class=\"sig\">").count - 1 == 1)
        #expect(html.components(separatedBy: "<blockquote>").count - 1 == 1)
        #expect(html.components(separatedBy: "</blockquote>").count - 1 == 1)

        // Order: typed body → signature → quote.
        let body = try! #require(html.range(of: "<strong>bold</strong>"))
        let sig = try! #require(html.range(of: "<div class=\"sig\">"))
        let quote = try! #require(html.range(of: "<blockquote>"))
        #expect(body.upperBound <= sig.lowerBound)
        #expect(sig.upperBound <= quote.lowerBound)

        // Nothing leaked across regions.
        #expect(html.contains("Ahmed<br>Ainkrad"))
        #expect(html.contains("original text"))
    }

    @Test("a forward — a quote with no typed reply body — still renders the quote")
    func forwardWithNoBodyStillQuotes() {
        let composed = ReplyComposer.quoteBody(mode: .forward, message: Self.quotedMessage,
                                               bodyText: "forwarded content")
        let html = MarkdownToHTML.renderComposed(composed)
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("forwarded content"))
        #expect(html.contains("wrote:"))
    }

    @Test("a forward with a signature but no typed body emits the signature above the quote")
    func forwardWithSignature() {
        let composed = ReplyComposer.quoteBody(mode: .forward, message: Self.quotedMessage,
                                               bodyText: "forwarded content")
            + Signature.sigdash + "Ahmed"
        let html = MarkdownToHTML.renderComposed(composed)
        let sig = try! #require(html.range(of: "<div class=\"sig\">"))
        let quote = try! #require(html.range(of: "<blockquote>"))
        #expect(sig.upperBound <= quote.lowerBound)
        #expect(html.contains("forwarded content"))
    }

    @Test("a message with no quote emits no blockquote at all")
    func noQuoteNoBlockquote() {
        let html = MarkdownToHTML.renderComposed("Just a plain new message.")
        #expect(html == "<p>Just a plain new message.</p>")
    }

    @Test("a nested block quote nests <blockquote> elements")
    func nestedBlockQuoteNests() {
        let html = MarkdownToHTML.render("> outer\n>\n> > inner")
        let opens = html.components(separatedBy: "<blockquote>").count - 1
        let closes = html.components(separatedBy: "</blockquote>").count - 1
        #expect(opens >= 2)
        #expect(opens == closes)
        #expect(html.contains("outer"))
        #expect(html.contains("inner"))
    }

    // MARK: Signature — the sigdash path

    @Test("a composed body + signature keeps every body line and an explicit signature separator")
    func composedBodyAndSignatureBothSurvive() {
        let composed = "Hi Bea,\n\nThanks for the update." + Signature.sigdash + "Ahmed\nAinkrad"
        let html = MarkdownToHTML.renderComposed(composed)

        // The regression: `--` parsed as a setext-h2 underline, so
        // "Thanks for the update." became a header block and was dropped,
        // the separator vanished, and the signature merged into body text.
        #expect(html.contains("<p>Hi Bea,</p>"))
        #expect(html.contains("<p>Thanks for the update.</p>"))
        // Recognisable as a signature, so a recipient's client can trim it.
        #expect(html.contains("-- <br>"))
        #expect(html.contains("Ahmed<br>Ainkrad"))
        // And no heading was invented from the sigdash.
        #expect(html.contains("<h2>") == false)
    }

    @Test("a body with no signature renders no signature block")
    func unsignedBodyHasNoSignatureBlock() {
        let html = MarkdownToHTML.renderComposed("Just a body.")
        #expect(html == "<p>Just a body.</p>")
        #expect(html.contains("sig") == false)
    }

    @Test("a signature is never Markdown-parsed, so its own punctuation cannot restructure it")
    func signatureIsLiteral() {
        let composed = "Body." + Signature.sigdash + "*Ahmed*\n# Ainkrad"
        let html = MarkdownToHTML.renderComposed(composed)
        #expect(html.contains("*Ahmed*"))
        #expect(html.contains("# Ainkrad"))
        #expect(html.contains("<em>") == false)
        #expect(html.contains("<h1>") == false)
    }

    // MARK: Other block kinds the dropping `default` used to swallow

    @Test("headers, code blocks and thematic breaks all emit markup instead of bare text")
    func previouslySwallowedKindsAreTagged() {
        #expect(MarkdownToHTML.render("# Title").contains("<h1>Title</h1>"))
        #expect(MarkdownToHTML.render("## Sub").contains("<h2>Sub</h2>"))
        let code = MarkdownToHTML.render("```\nlet x = 1\n```")
        #expect(code.contains("<pre><code>"))
        #expect(code.contains("let x = 1"))
        #expect(MarkdownToHTML.render("text\n\n---\n\nmore").contains("<hr>"))
    }

    @Test("no block kind loses its text")
    func noKindDropsText() {
        let sources = ["> quoted", "# heading", "```\ncode\n```", "- bullet",
                       "1. numbered", "|a|b|\n|-|-|\n|c|d|", "plain paragraph"]
        for source in sources {
            let html = MarkdownToHTML.render(source)
            #expect(!html.isEmpty, "\(source) rendered nothing")
        }
        let table = MarkdownToHTML.render("|a|b|\n|-|-|\n|c|d|")
        #expect(table.contains("c"))
        #expect(table.contains("d"))
    }

    // MARK: Escaping (unchanged behaviour, guarded)

    @Test("literal HTML in the source and in a signature is escaped, never live markup")
    func htmlIsEscaped() {
        #expect(MarkdownToHTML.render("<script>alert(1)</script>")
            .contains("&lt;script&gt;"))
        let signed = MarkdownToHTML.renderComposed(
            "Body." + Signature.sigdash + "<img src=x onerror=1>")
        #expect(signed.contains("&lt;img"))
        #expect(signed.contains("<img") == false)
    }
}

/// `Signature.split` is what keeps the sigdash away from the Markdown parser.
@Suite("Signature splitting")
struct SignatureTests {
    @Test("splits at the sigdash")
    func splitsAtSigdash() {
        let (body, signature) = Signature.split("Body text" + Signature.sigdash + "Ahmed")
        #expect(body == "Body text")
        #expect(signature == "Ahmed")
    }

    @Test("no sigdash means no signature and an untouched body")
    func noSigdash() {
        let (body, signature) = Signature.split("Body text")
        #expect(body == "Body text")
        #expect(signature == nil)
    }

    @Test("a quoted sigdash is not mistaken for the signature separator")
    func quotedSigdashIsNotTheSeparator() {
        // The quoted original's own sigdash arrives as `\n> -- \n`, which must
        // not match `\n-- \n`.
        let composed = "Reply.\n\nOn 1 Jan, Bea wrote:\n> body\n> -- \n> Bea"
        let (body, signature) = Signature.split(composed)
        #expect(signature == nil)
        #expect(body == composed)
    }

    @Test("splits at the LAST sigdash, so a sigdash the user typed stays in the body")
    func splitsAtLastSigdash() {
        let composed = "Quoting someone" + Signature.sigdash + "their sig"
            + Signature.sigdash + "Ahmed"
        let (body, signature) = Signature.split(composed)
        #expect(body == "Quoting someone" + Signature.sigdash + "their sig")
        #expect(signature == "Ahmed")
    }
}

/// `QuotedRegion` is what keeps a quoted original away from the Markdown
/// parser. It splits at the same boundary `QuoteTrimmer` uses, so the send path
/// and the thread view cannot disagree about where a quote begins.
@Suite("Quoted region splitting")
struct QuotedRegionTests {
    private static let message = MailMessage(
        id: "m1", threadID: "t1", rfc822MessageID: "<a@b>",
        from: MailAddress(email: "bea@example.com", name: "Bea"),
        subject: "hello", date: Date(timeIntervalSince1970: 1_700_000_000))

    @Test("a ReplyComposer body splits into typed text, attribution, and quoted lines")
    func splitsAReplyComposerBody() {
        let composed = "My reply." + ReplyComposer.quoteBody(
            mode: .reply, message: Self.message, bodyText: "line one\nline two")
        let split = QuotedRegion.split(composed)
        #expect(split.body == "My reply.")
        #expect(split.attribution?.hasPrefix("On ") == true)
        #expect(split.attribution?.hasSuffix("wrote:") == true)
        #expect(split.quotedLines == ["line one", "line two"])
    }

    @Test("exactly one quote level is stripped; a nested quote's own markers stay as text")
    func stripsOneQuoteLevel() {
        let composed = "Reply.\n\nOn 1 Jan, Bea wrote:\n> outer\n> > inner\n>bare"
        #expect(QuotedRegion.split(composed).quotedLines == ["outer", "> inner", "bare"])
    }

    @Test("no quote means the whole text is body and there are no quoted lines")
    func noQuote() {
        let split = QuotedRegion.split("Just a message.")
        #expect(split.body == "Just a message.")
        #expect(split.attribution == nil)
        #expect(split.quotedLines == nil)
    }

    @Test("a forward with no typed body yields an empty body and the quote intact")
    func forwardHasEmptyBody() {
        let composed = ReplyComposer.quoteBody(mode: .forward, message: Self.message,
                                               bodyText: "forwarded")
        let split = QuotedRegion.split(composed)
        #expect(split.body.isEmpty)
        #expect(split.quotedLines == ["forwarded"])
    }

    @Test("blank lines inside a quote are kept, but the trailing join artefact is not")
    func keepsInteriorBlankLines() {
        let composed = "Reply.\n\nOn 1 Jan, Bea wrote:\n> one\n>\n> two\n> \n> "
        #expect(QuotedRegion.split(composed).quotedLines == ["one", "", "two"])
    }
}
