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
        let message = MailMessage(
            id: "m1", threadID: "t1", rfc822MessageID: "<a@b>",
            from: MailAddress(email: "bea@example.com", name: "Bea"),
            to: [], cc: [], subject: "Re: hello",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: true, isStarred: false, labelIDs: [], hasAttachments: false,
            snippet: "", attachments: [])
        let quoted = ReplyComposer.quoteBody(mode: .reply, message: message,
                                             bodyText: "quoted line\nsecond quoted line")
        let html = MarkdownToHTML.render("This is a reply." + quoted)

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

    @Test("splits at the LAST sigdash, so a sigdash the user typed stays in the body")
    func splitsAtLastSigdash() {
        let composed = "Quoting someone" + Signature.sigdash + "their sig"
            + Signature.sigdash + "Ahmed"
        let (body, signature) = Signature.split(composed)
        #expect(body == "Quoting someone" + Signature.sigdash + "their sig")
        #expect(signature == "Ahmed")
    }
}
