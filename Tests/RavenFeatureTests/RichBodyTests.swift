import Testing
import Foundation
@testable import RavenFeature

/// The document model, and the decode rule that keeps a body this build only
/// partly understands from costing more than the formatting it describes.
///
/// The stranding history this guards is specific: `Outbox` loaded its queue
/// with one `try?` over the whole array, so a single entry this build could not
/// read discarded every queued send. That is now per-entry, but an entry is
/// made of an `OutgoingMessage`, so a throw *inside* one is still an entry
/// lost. The rules below — `bodyText` required and verbatim, `richBody`
/// additive and optional, spans lenient one at a time — are what keep the worst
/// case at "one message goes out unformatted".
@Suite("Rich body")
struct RichBodyTests {
    private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Old document → new build

    /// The blob below is written out by hand, in the shape the CURRENT build
    /// persists: no `richBody` key at all, `bodyText` a plain string. It is
    /// deliberately NOT produced by this build's encoder — an expectation
    /// computed by the code it is checking would pass no matter what the rule
    /// became.
    ///
    /// The body is chosen to break a converter rather than to be easy: `**` and
    /// `_` that must NOT become bold or italic, a `- ` that must not become a
    /// bullet, a `> ` quote line, and a sigdash. If any conversion step existed
    /// on the load path, one of these would come back changed.
    private let preM6Draft = """
    {
      "to": [{"email": "bea@example.test", "name": "Bea"}],
      "cc": [],
      "bcc": [],
      "subject": "Subject 1",
      "bodyText": "Hi Bea,\\n\\nUse **two stars** and a _underscore_.\\n- not a bullet\\n\\n> quoted line\\n\\n-- \\nSig",
      "attachments": []
    }
    """

    @Test("a draft persisted before M6 opens with its text intact and no rich body")
    func preM6DraftDecodesVerbatim() throws {
        let message = try decoded(OutgoingMessage.self, preM6Draft)

        // Written out independently of the blob's escaping, so the assertion
        // cannot agree with the fixture by construction.
        let expected = "Hi Bea,\n\nUse **two stars** and a _underscore_.\n"
            + "- not a bullet\n\n> quoted line\n\n-- \nSig"
        #expect(message.bodyText == expected)
        #expect(message.richBody == nil)
        #expect(message.subject == "Subject 1")
    }

    @Test("opening a pre-M6 draft in the composer yields plain text with no spans")
    func preM6DraftOpensAsPlain() throws {
        let message = try decoded(OutgoingMessage.self, preM6Draft)

        // Exactly what `ComposeSurface.load` does with a draft's body.
        let opened = message.richBody ?? RichBody(plainText: message.bodyText)

        #expect(opened.text == message.bodyText)
        #expect(opened.spans.isEmpty)
        #expect(opened.isPlain)
    }

    // MARK: Round trip

    /// One span of every kind the model supports.
    ///
    /// This list is a test-local literal, so it does NOT by itself stop a
    /// ninth kind from being added and going untested — a kind simply absent
    /// from here leaves the count at eight. What forces a new kind to be
    /// handled deliberately is the exhaustive switches with no `default:` in
    /// `RichBody.Kind.tag`, `RichBody.Kind.isBlock`, `RichTextBridge.applyKind`,
    /// `RichTextBridge.blockStyle` and `RichTextBridge.order`: adding a case
    /// stops the build until each is answered.
    private var everyKind: [RichBody.Kind] {
        [.bold, .italic, .underline, .code,
         .link(URL(string: "https://example.test/a?b=1&c=2")!),
         .bulletItem, .numberItem, .blockquote]
    }

    @Test("a rich body round-trips through JSON preserving every supported attribute")
    func roundTripPreservesEveryKind() throws {
        let text = "0123456789abcdefghij"
        let spans = everyKind.enumerated().map {
            RichBody.Span(start: $0.offset * 2, length: 2, kind: $0.element)
        }
        let body = RichBody(text: text, spans: spans)
        #expect(body.spans.count == 8)

        let data = try JSONEncoder().encode(body)
        let back = try JSONDecoder().decode(RichBody.self, from: data)

        #expect(back == body)
        #expect(back.text == text)
        #expect(back.spans.map(\.kind) == everyKind)
        #expect(back.spans.map(\.start) == [0, 2, 4, 6, 8, 10, 12, 14])
        // The URL survives whole — query string included, not just the host.
        guard case .link(let url) = back.spans[4].kind else {
            Issue.record("the link span did not decode as a link")
            return
        }
        #expect(url.absoluteString == "https://example.test/a?b=1&c=2")
    }

    // MARK: Lenient span decoding

    @Test("an unsupported attribute degrades to plain text rather than throwing")
    func unknownSpanKindDegrades() throws {
        // A future build's kind sitting between two this build knows.
        let json = """
        {"text": "one two three",
         "spans": [{"start": 0, "length": 3, "kind": "bold"},
                   {"start": 4, "length": 3, "kind": "strikethrough"},
                   {"start": 8, "length": 5, "kind": "italic"}]}
        """

        let body = try decoded(RichBody.self, json)

        // The text is untouched — the unknown run is still there as characters,
        // it simply has no formatting.
        #expect(body.text == "one two three")
        #expect(body.spans.count == 2)
        #expect(body.spans.map(\.kind) == [.bold, .italic])
        #expect(body.spans.map(\.start) == [0, 8])
    }

    @Test("a link whose address is not a URL costs that span only")
    func unusableLinkURLDegrades() throws {
        let json = """
        {"text": "one two", "spans": [{"start": 0, "length": 3, "kind": "link"},
                                      {"start": 4, "length": 3, "kind": "bold"}]}
        """

        let body = try decoded(RichBody.self, json)

        #expect(body.text == "one two")
        #expect(body.spans.map(\.kind) == [.bold])
    }

    @Test("a span outside the text is dropped, not clamped")
    func outOfRangeSpanIsDropped() throws {
        let json = """
        {"text": "short", "spans": [{"start": 3, "length": 40, "kind": "bold"},
                                    {"start": 0, "length": 5, "kind": "italic"}]}
        """

        let body = try decoded(RichBody.self, json)

        // Clamping to (3, 2) would guess at an intent nothing recorded; the
        // run degrades to plain instead, and the good span is unaffected.
        #expect(body.spans.map(\.kind) == [.italic])
        #expect(body.spans.map(\.length) == [5])
    }

    @Test("a rich body with no spans key decodes as plain")
    func missingSpansKeyDecodesAsPlain() throws {
        let body = try decoded(RichBody.self, #"{"text": "just text"}"#)

        #expect(body.text == "just text")
        #expect(body.isPlain)
    }

    // MARK: The message, both directions

    @Test("an unreadable rich body costs the formatting, never the message")
    func unreadableRichBodyKeepsTheMessage() throws {
        // A future build storing something else entirely under the key. A throw
        // here would fail the whole `OutgoingMessage`, and an `OutgoingMessage`
        // is what a queued send is made of.
        let json = """
        {"to": [{"email": "bea@example.test"}], "cc": [], "bcc": [],
         "subject": "Subject 1", "bodyText": "Hello", "attachments": [],
         "richBody": "a future shape"}
        """

        let message = try decoded(OutgoingMessage.self, json)

        #expect(message.bodyText == "Hello")
        #expect(message.richBody == nil)
        #expect(message.to.first?.email == "bea@example.test")
    }

    /// Exactly what `ComposeSurface.message()` calls, with the composer's own
    /// arguments. Asserting on `OutgoingMessage(to:subject:bodyText:)` instead
    /// would only exercise the initializer's `richBody` DEFAULT — a path that
    /// cannot fail — and would leave the one producer that can actually attach
    /// a rich body to a plain message unasserted.
    private func composed(_ body: RichBody) -> OutgoingMessage {
        ComposeMessage.outgoing(to: [MailAddress(email: "bea@example.test")], cc: [], bcc: [],
                                subject: "Subject 1", body: body, attachments: [])
    }

    @Test("a body typed with no formatting writes no richBody key at all")
    func composingPlainTextOmitsTheKey() throws {
        let json = String(decoding: try JSONEncoder().encode(composed(RichBody(plainText: "Hello"))),
                          as: UTF8.self)

        // The forward-compatibility guarantee is byte-level: a build that never
        // heard of `richBody` must see exactly the document it always saw. An
        // empty rich body attached here would be invisible on screen and
        // present in every stored draft and queued send.
        #expect(!json.contains("richBody"))
        #expect(json.contains("\"bodyText\":\"Hello\""))
    }

    @Test("a body typed WITH formatting does attach it, beside the same plain text")
    func composingFormattedTextAttachesTheBody() throws {
        let message = composed(RichBody(text: "Hello",
                                        spans: [RichBody.Span(start: 0, length: 5, kind: .bold)]))

        #expect(message.bodyText == "Hello")
        #expect(message.richBody?.spans.map(\.kind) == [.bold])
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(json.contains("richBody"))
    }

    @Test("a formatted message still carries bodyText verbatim for an older build")
    func formattedMessageKeepsPlainBodyText() throws {
        let rich = RichBody(text: "Hello there",
                            spans: [RichBody.Span(start: 0, length: 5, kind: .bold)])
        let message = OutgoingMessage(to: [MailAddress(email: "bea@example.test")],
                                      subject: "Subject 1", bodyText: "Hello there",
                                      richBody: rich)

        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(message)) as? [String: Any]

        // An older build reads this key, sends a correct plain-text message,
        // and loses only the bold.
        #expect(object?["bodyText"] as? String == "Hello there")
        #expect(object?["richBody"] != nil)
    }

    @Test("bodyText stays authoritative when a caller hands over a disagreeing rich body")
    func richBodyIsAnchoredToBodyText() {
        // The `SendAttempt.withSignature` hazard in miniature: a rebuild that
        // updates one of the two fields and not the other.
        let stale = RichBody(text: "Hello",
                             spans: [RichBody.Span(start: 0, length: 5, kind: .bold)])
        let message = OutgoingMessage(to: [MailAddress(email: "bea@example.test")],
                                      subject: "Subject 1",
                                      bodyText: "Hello and then some",
                                      richBody: stale)

        #expect(message.richBody?.text == message.bodyText)
        // The span still addresses real characters, so it survives the
        // re-anchoring rather than being thrown away with it.
        #expect(message.richBody?.spans.map(\.kind) == [.bold])
    }

    @Test("a rich body whose spans no longer fit the authoritative text loses the spans only")
    func anchoringDropsSpansThatNoLongerFit() {
        let stale = RichBody(text: "a much longer body",
                             spans: [RichBody.Span(start: 10, length: 8, kind: .italic)])
        let message = OutgoingMessage(to: [MailAddress(email: "bea@example.test")],
                                      subject: "Subject 1", bodyText: "short",
                                      richBody: stale)

        #expect(message.bodyText == "short")
        #expect(message.richBody?.text == "short")
        #expect(message.richBody?.spans.isEmpty == true)
    }

    // MARK: Plain-text derivation

    @Test("plain-text derivation is the identity for anything that was plain")
    func plainDerivationIsLossless() {
        // Each of these is something a lossy round trip would change: CRLF,
        // trailing spaces, a sigdash, quote prefixes, an emoji outside the BMP,
        // and RTL text.
        let samples = [
            "Hi Bea,\r\n\r\nThanks.",
            "trailing spaces   \n\nand a tab\there",
            "Body\n-- \nSignature",
            "> quoted\n> lines\n\nreply",
            "family 👨‍👩‍👧‍👦 emoji",
            "مرحبا بالعالم"
        ]

        for sample in samples {
            #expect(RichBody(plainText: sample).plainText == sample)
            // And through the composer's own message construction.
            let message = OutgoingMessage(to: [MailAddress(email: "b@example.test")],
                                          subject: "Subject 1", bodyText: sample)
            #expect(message.bodyText == sample)
        }
    }

    @Test("RTL detection reads the same string it always did")
    func rtlDetectionUnchanged() {
        let arabic = RichBody(text: "مرحبا بالعالم\n\n> On Monday, a@example.test wrote:\n> hello",
                              spans: [RichBody.Span(start: 0, length: 5, kind: .bold)])

        #expect(BaseTextDirection.detect(arabic.text) == .rightToLeft)
        #expect(BaseTextDirection.detect(RichBody(plainText: "Hello there").text) == .leftToRight)
    }
}
