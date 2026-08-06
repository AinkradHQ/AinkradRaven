import AppKit
import Foundation

/// The one translation between `RichBody` and what an `NSTextView` edits.
///
/// It is the enforcement point for the allowlist in both directions: an
/// attribute that is not a `RichBody.Kind` is never written INTO the editor and
/// never read OUT of it, so a paste carrying a website's font stack, pixel
/// sizes, colours or background contributes exactly the kinds below and nothing
/// else. Bold is a font *trait*, never a colour — nothing a document can
/// contain is able to produce text invisible against a changed theme.
///
/// Pure, and deliberately not a view: every rule here is assertable without
/// presenting anything.
enum RichTextBridge {
    /// Marks a `code` run. There is no native AppKit attribute for it, and the
    /// monospaced font alone is not a reliable signal — a paste can carry one
    /// for reasons of its own — so the run is marked explicitly.
    static let codeAttribute = NSAttributedString.Key("ravenRichCode")
    /// Marks a block-level run (`bulletItem`, `numberItem`, `blockquote`) with
    /// the kind's stored tag.
    static let blockAttribute = NSAttributedString.Key("ravenRichBlock")

    /// Indent applied to a list item, in points.
    static let blockIndent: CGFloat = 18

    /// The paragraph geometry that makes a block kind recognisable on screen.
    ///
    /// **Visual only, and geometry only** — the characters of `RichBody.text`
    /// are untouched, which is the whole reason `NSTextList` is not used: it
    /// writes its markers INTO the text storage, and the plain text must stay
    /// exactly what the user typed.
    ///
    /// The three must be *distinguishable from each other*, because Task 21
    /// renders them as three different tags: a composer in which a bullet, a
    /// numbered item and a quote look identical is a UI lying about the
    /// document. Without a glyph marker the only honest signal left is
    /// geometry, so: a bullet is indented once, a numbered item twice (its
    /// markers are wider), and a quote is inset from BOTH margins with air
    /// above and below, which reads as a quote and as nothing else.
    static func blockStyle(_ kind: RichBody.Kind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch kind {
        case .blockquote:
            style.firstLineHeadIndent = blockIndent
            style.headIndent = blockIndent
            style.tailIndent = -blockIndent
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 6
        case .numberItem:
            style.firstLineHeadIndent = blockIndent * 2
            style.headIndent = blockIndent * 2
        // Exhaustive rather than `default:` so a block kind added later has to
        // be given its own geometry here instead of silently sharing the
        // bullet's.
        case .bulletItem, .bold, .italic, .underline, .code, .link:
            style.firstLineHeadIndent = blockIndent
            style.headIndent = blockIndent
        }
        return style
    }

    // MARK: Model → editor

    static func attributedString(_ body: RichBody, font: NSFont, color: NSColor)
        -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: body.text, attributes: [.font: font, .foregroundColor: color])
        for span in body.spans {
            applyKind(span.kind, to: out,
                      range: NSRange(location: span.start, length: span.length), baseFont: font)
        }
        return out
    }

    /// Writes one kind's attributes over `range`. Internal, not private: a
    /// format-bar command applies the same kinds and must not get a second,
    /// drifting copy of the rule.
    static func applyKind(_ kind: RichBody.Kind, to out: NSMutableAttributedString,
                          range: NSRange, baseFont: NSFont) {
        switch kind {
        case .bold: addTrait(.boldFontMask, to: out, range: range)
        case .italic: addTrait(.italicFontMask, to: out, range: range)
        case .underline:
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                             range: range)
        case .code:
            out.addAttribute(codeAttribute, value: true, range: range)
            out.addAttribute(.font,
                             value: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize,
                                                                weight: .regular),
                             range: range)
        case .link(let url):
            out.addAttribute(.link, value: url, range: range)
        case .bulletItem, .numberItem, .blockquote:
            out.addAttribute(blockAttribute, value: kind.tag, range: range)
            out.addAttribute(.paragraphStyle, value: blockStyle(kind), range: range)
        }
    }

    private static func addTrait(_ trait: NSFontTraitMask, to out: NSMutableAttributedString,
                                 range: NSRange) {
        out.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            out.addAttribute(.font,
                             value: NSFontManager.shared.convert(font, toHaveTrait: trait),
                             range: sub)
        }
    }

    // MARK: Editor → model

    /// Reads the document back out. Only allowlisted attributes are read, so
    /// whatever else is in the storage cannot reach the model — and therefore
    /// cannot reach the wire.
    static func richBody(from attributed: NSAttributedString) -> RichBody {
        RichBody(text: attributed.string,
                 spans: spans(in: attributed,
                              range: NSRange(location: 0, length: attributed.length)))
    }

    /// The allowlisted runs inside `range`, coalesced and ordered by start.
    static func spans(in attributed: NSAttributedString, range: NSRange) -> [RichBody.Span] {
        var runs: [(RichBody.Kind, NSRange)] = []
        attributed.enumerateAttributes(in: range) { attrs, sub, _ in
            for kind in kinds(of: attrs) { runs.append((kind, sub)) }
        }
        return coalesce(runs)
    }

    /// The kinds one run's attributes map to. Everything not named here — font
    /// family, size, colour, background, kerning, shadow, a website's
    /// stylesheet — is simply not read.
    private static func kinds(of attrs: [NSAttributedString.Key: Any]) -> [RichBody.Kind] {
        var kinds: [RichBody.Kind] = []
        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { kinds.append(.bold) }
            if traits.contains(.italicFontMask) { kinds.append(.italic) }
        }
        if let style = attrs[.underlineStyle] as? Int, style != 0 { kinds.append(.underline) }
        if attrs[codeAttribute] as? Bool == true { kinds.append(.code) }
        if let url = linkURL(attrs[.link]) { kinds.append(.link(url)) }
        if let tag = attrs[blockAttribute] as? String, let block = blockKind(tag) {
            kinds.append(block)
        }
        return kinds
    }

    /// AppKit hands a link back as an `NSURL` or as a `String`, depending on
    /// who wrote it — our own writer, or its HTML reader on a paste.
    private static func linkURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func blockKind(_ tag: String) -> RichBody.Kind? {
        switch tag {
        case "bulletItem": return .bulletItem
        case "numberItem": return .numberItem
        case "blockquote": return .blockquote
        default: return nil
        }
    }

    /// Merges adjacent runs of the same kind, so a document whose storage
    /// happens to be split into several runs (which a paste, or a second
    /// attribute applied over part of a run, produces) yields the same spans as
    /// the same document in one run.
    private static func coalesce(_ runs: [(RichBody.Kind, NSRange)]) -> [RichBody.Span] {
        var merged: [RichBody.Kind: [NSRange]] = [:]
        for (kind, range) in runs {
            var list = merged[kind] ?? []
            if let last = list.last, NSMaxRange(last) == range.location {
                list[list.count - 1] = NSUnionRange(last, range)
            } else {
                list.append(range)
            }
            merged[kind] = list
        }
        return merged
            .flatMap { kind, ranges in
                ranges.map { RichBody.Span(start: $0.location, length: $0.length, kind: kind) }
            }
            .sorted { ($0.start, order($0.kind)) < ($1.start, order($1.kind)) }
    }

    /// A total order over kinds, so the span list is deterministic — two equal
    /// documents must produce byte-equal JSON, or a draft would autosave on
    /// every render.
    private static func order(_ kind: RichBody.Kind) -> Int {
        switch kind {
        case .bold: return 0
        case .italic: return 1
        case .underline: return 2
        case .code: return 3
        case .link: return 4
        case .bulletItem: return 5
        case .numberItem: return 6
        case .blockquote: return 7
        }
    }

    // MARK: Paste normalisation

    /// Strips everything outside the allowlist from a just-pasted range and
    /// re-applies what survived, over the composer's own font and colour.
    ///
    /// The read AppKit performed is kept — bold stays bold, a link stays a
    /// link — while the source document's font stack, sizes, colours and
    /// background do not survive the round trip through `spans(in:range:)`,
    /// because that function cannot express them.
    static func normalize(_ storage: NSTextStorage, in range: NSRange,
                          font: NSFont, color: NSColor) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let found = spans(in: storage, range: range)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: color], range: range)
        for span in found {
            applyKind(span.kind, to: storage,
                  range: NSRange(location: span.start, length: span.length), baseFont: font)
        }
        storage.endEditing()
    }
}
