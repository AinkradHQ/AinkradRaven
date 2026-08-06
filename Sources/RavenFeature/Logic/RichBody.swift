import Foundation

/// A composed body: **the plain text, plus formatting described beside it.**
///
/// The load-bearing property is that `text` is not derived from anything. It is
/// the string the user's keystrokes produced, with `\n` where they pressed
/// Return and `> ` where `ReplyComposer` put it. Formatting is stored *beside*
/// it, never *instead of* it, so the `text/plain` part of a sent message is the
/// identity function on `text` — no HTML→text pass, no lossy round trip, and
/// nothing for `QuoteTrimmer` or a recipient's signature trimming to lose.
///
/// The cost of that shape, stated: a text-plus-spans model can only express
/// formatting that has a plain-text projection. A table, an inline image or a
/// horizontal rule has no characters behind it and **degrades to its text**.
/// That is deliberate — see the M6 rich-compose design note, decision 5.
///
/// Offsets are UTF-16 code units because `NSAttributedString` and `NSRange`
/// are UTF-16-native: converting once, at the editor boundary, is one
/// conversion, where character offsets would convert on every editor round
/// trip and invite an off-by-one on every emoji.
public struct RichBody: Equatable, Sendable {
    /// Exactly the plain-text part, byte for byte.
    public let text: String
    /// Formatting runs over `text`. Always in the order given, always valid
    /// against `text` — see `RichBody.init(text:spans:)`.
    public let spans: [Span]

    /// A single formatting run.
    public struct Span: Equatable, Sendable {
        /// UTF-16 code-unit offset into `RichBody.text`.
        public let start: Int
        /// Length in UTF-16 code units. Always > 0 on a stored span.
        public let length: Int
        public let kind: Kind

        public init(start: Int, length: Int, kind: Kind) {
            self.start = start; self.length = length; self.kind = kind
        }

        /// Whether this run addresses real characters of a `text` whose length
        /// in UTF-16 code units is `utf16Count`.
        ///
        /// A span that fails this is **dropped, never clamped**: a clamp
        /// guesses at an intent nothing recorded, where a drop degrades that
        /// one run to plain text and leaves every character intact.
        func isValid(in utf16Count: Int) -> Bool {
            start >= 0 && length > 0 && start + length <= utf16Count
        }
    }

    /// The formatting this model can express — and, deliberately, the same set
    /// the editor keeps on paste and the renderer can emit. One list, defined
    /// once. Widening it later is easy; narrowing it is not, because a tag that
    /// has been emitted exists in sent mail people will quote back.
    ///
    /// No colours, fonts or sizes are in it, on purpose: a bold run is a font
    /// *trait*, so nothing in a document can produce text that is invisible
    /// against a changed theme, or that defeats a recipient's dark mode.
    public enum Kind: Equatable, Sendable, Hashable {
        case bold
        case italic
        case underline
        case code
        case link(URL)
        case bulletItem
        case numberItem
        case blockquote

        /// The stored discriminator. Stable: these strings are in persisted
        /// drafts and queued sends, so a value may be added but never renamed.
        var tag: String {
            switch self {
            case .bold: return "bold"
            case .italic: return "italic"
            case .underline: return "underline"
            case .code: return "code"
            case .link: return "link"
            case .bulletItem: return "bulletItem"
            case .numberItem: return "numberItem"
            case .blockquote: return "blockquote"
            }
        }
    }

    /// Builds a body, **dropping every span that does not address real
    /// characters of `text`**. This is the only initializer, so an invalid span
    /// cannot exist on a `RichBody` however it was produced — decoded from a
    /// document, read out of the editor, or written by hand in a test.
    public init(text: String = "", spans: [Span] = []) {
        self.text = text
        let count = text.utf16.count
        self.spans = spans.filter { $0.isValid(in: count) }
    }

    /// A body that was never formatted. The `nil`-`richBody` decode and every
    /// plain producer (`create_draft`, `ReplyComposer`, a pre-M6 draft) land
    /// here, and land with **no formatting artefacts**, because there is no
    /// conversion step in which one could be introduced.
    public init(plainText: String) {
        self.init(text: plainText, spans: [])
    }

    /// Whether this carries any formatting at all. A body that does not is
    /// indistinguishable from a plain `String` and is stored as one — see
    /// `OutgoingMessage.richBody`.
    public var isPlain: Bool { spans.isEmpty }

    /// The `text/plain` derivation: the identity function. Named rather than
    /// inlined so the call sites say what they mean, and so the one place the
    /// derivation could ever stop being lossless is this line.
    public var plainText: String { text }
}

/// Assembling the composed message.
///
/// This lives beside the model rather than inside `ComposeSurface` for one
/// reason: `attachment(for:)` below is the only place in the app that decides
/// whether a message carries a `richBody` at all, and getting it wrong breaks
/// byte-identity of the stored document for every older build — a rule inside
/// a SwiftUI `View` cannot be asserted, and this one has to be.
public enum ComposeMessage {
    /// The value an `OutgoingMessage` should carry for a composed body.
    ///
    /// `nil` when nothing was formatted, so a message typed without formatting
    /// encodes exactly as it did before M6 — no `richBody` key, byte for byte
    /// the document an older build already reads, and the `MarkdownToHTML`
    /// path on the wire. Attaching an empty rich body instead would be
    /// invisible here and visible in every stored draft and queued send.
    public static func attachment(for body: RichBody) -> RichBody? {
        body.isPlain ? nil : body
    }

    /// The typed content as an `OutgoingMessage`, before routing.
    public static func outgoing(to: [MailAddress], cc: [MailAddress], bcc: [MailAddress],
                                subject: String, body: RichBody,
                                attachments: [OutgoingAttachment]) -> OutgoingMessage {
        OutgoingMessage(to: to, cc: cc, bcc: bcc, subject: subject,
                        // The plain text, verbatim — `bodyText` never stops
                        // being the truth about the `text/plain` part.
                        bodyText: body.text,
                        attachments: attachments,
                        richBody: attachment(for: body))
    }
}

// MARK: - Coding

/// The stored shape, and the leniency rules that keep an unreadable *span* from
/// costing more than that span.
///
/// **Reading a document written before this shipped.** `richBody` is absent, so
/// `OutgoingMessage` decodes `RichBody(plainText: bodyText)` — text intact, no
/// spans, nothing to convert.
///
/// **An older build reading a document written by this one.**
/// `OutgoingMessage.init(from:)` reads only the keys it knows, so an older
/// build reads `bodyText` (which is still required, still verbatim) and ignores
/// `richBody` entirely. It loses the formatting; it strands nothing. That is
/// why `bodyText` may never be removed or made optional: it is the only thing
/// standing between a rollback and an outbox that will not load.
///
/// **A `richBody` this build only partly understands.** `spans` is
/// `decodeIfPresent ?? []`; each span decodes individually through
/// `LenientSpan`, so an unrecognised `kind` — or a `link` with no usable URL,
/// or a run outside `text` — costs that one span and degrades it to plain text
/// rather than throwing out of the array, out of the message, and (given
/// `Outbox`'s array-level decode) potentially out of the whole queue.
extension RichBody: Codable {
    private enum CodingKeys: String, CodingKey { case text, spans }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .text)
        let stored = try c.decodeIfPresent([LenientSpan].self, forKey: .spans) ?? []
        self.init(text: text, spans: stored.compactMap(\.span))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(spans, forKey: .spans)
    }

    /// Wraps one stored span so a decode failure produces `nil` instead of
    /// throwing out of the surrounding array — the same shape
    /// `OutboxQueueCodec.LenientEntry` uses for an outbox entry and
    /// `IMAPSyncCursor.LenientState` for its mailbox map.
    private struct LenientSpan: Decodable {
        let span: Span?
        init(from decoder: Decoder) throws { span = try? Span(from: decoder) }
    }
}

extension RichBody.Span: Codable {
    fileprivate enum CodingKeys: String, CodingKey { case start, length, kind, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int.self, forKey: .start)
        length = try c.decode(Int.self, forKey: .length)
        let tag = try c.decode(String.self, forKey: .kind)
        kind = try RichBody.Kind(tag: tag, container: c)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(length, forKey: .length)
        try c.encode(kind.tag, forKey: .kind)
        if case .link(let url) = kind { try c.encode(url.absoluteString, forKey: .url) }
    }
}

private extension RichBody.Kind {
    /// Throws for a tag this build does not know, which `LenientSpan` turns
    /// into "this one run is plain text" — never into a refused message.
    init(tag: String, container: KeyedDecodingContainer<RichBody.Span.CodingKeys>) throws {
        switch tag {
        case "bold": self = .bold
        case "italic": self = .italic
        case "underline": self = .underline
        case "code": self = .code
        case "bulletItem": self = .bulletItem
        case "numberItem": self = .numberItem
        case "blockquote": self = .blockquote
        case "link":
            let raw = try container.decode(String.self, forKey: .url)
            guard let url = URL(string: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url, in: container,
                    debugDescription: "Not a URL; the run degrades to plain text.")
            }
            self = .link(url)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "Unknown span kind \(tag); the run degrades to plain text.")
        }
    }
}
