import Foundation

/// The *base* direction a body of text should be laid out in.
///
/// This is deliberately NOT a bidi implementation. The Unicode Bidirectional
/// Algorithm already reorders runs correctly inside a paragraph on every
/// platform that renders text — what it cannot guess is the *paragraph*
/// direction, which is a property of the document, not of the characters. Get
/// that wrong and an Arabic message composes and arrives with its punctuation
/// at the wrong end, its lines flush left, and any embedded Latin run pushed
/// to the wrong side. So the only job here is to pick `ltr` or `rtl` and hand
/// it to the system (SwiftUI's `layoutDirection` for the editor, an HTML `dir`
/// attribute for the transmitted message) and let the real algorithm work.
public enum BaseTextDirection: String, Equatable, Sendable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"

    /// The HTML `dir` attribute value.
    public var htmlDir: String { rawValue }
}

public extension BaseTextDirection {
    /// Whether `scalar` is a strong right-to-left character (Arabic, Hebrew,
    /// Syriac, Thaana, N'Ko, Samaritan, and the Arabic presentation forms).
    ///
    /// Ranges rather than a `CharacterSet` so the classification is visible and
    /// testable; digits, punctuation, whitespace and symbols are intentionally
    /// *neutral* — a line of "١٢٣ - 456" says nothing about base direction.
    static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF,   // Hebrew
             0x0600...0x06FF,   // Arabic
             0x0700...0x074F,   // Syriac
             0x0750...0x077F,   // Arabic Supplement
             0x0780...0x07BF,   // Thaana
             0x07C0...0x07FF,   // N'Ko
             0x0800...0x083F,   // Samaritan
             0x0840...0x085F,   // Mandaic
             0x0860...0x08FF,   // Syriac Supplement, Arabic Extended-A
             0xFB1D...0xFDFF,   // Hebrew/Arabic presentation forms A
             0xFE70...0xFEFF,   // Arabic presentation forms B
             0x10800...0x10FFF, // Cypriot … Old Hungarian
             0x1E800...0x1EFFF: // Mende Kikakui … Arabic Mathematical
            return true
        default:
            return false
        }
    }

    /// Whether `scalar` is a strong left-to-right letter. Only *letters* count:
    /// an Arabic paragraph containing a URL or a product code must not be
    /// dragged left-to-right by it.
    static func isStrongLTR(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic else { return false }
        return !isStrongRTL(scalar)
    }

    /// The predominant direction of `text`, by strong-character majority.
    ///
    /// Only the portion the user actually authored is weighed — replying in
    /// Arabic to a long English thread must compose right-to-left, and an
    /// English attribution line plus a quoted original that outweighs the reply
    /// ten to one would otherwise decide the direction of what the user is
    /// writing. Ties and "no strong characters at all" resolve to
    /// `leftToRight`, which is the safe default — it is what every existing
    /// message already got.
    static func detect(_ text: String) -> BaseTextDirection {
        let considered = authoredPortion(of: text)
        var rtl = 0
        var ltr = 0
        for scalar in considered.unicodeScalars {
            if isStrongRTL(scalar) { rtl += 1 } else if isStrongLTR(scalar) { ltr += 1 }
        }
        return rtl > ltr ? .rightToLeft : .leftToRight
    }

    /// The newly-typed part of a composed body: signature stripped by
    /// `Signature.split`, attribution line and quoted original stripped by
    /// `QuotedRegion.split`. Both already exist and are already under test —
    /// re-deriving "what counts as a quote" here would be a second, divergent
    /// answer to a question this module has already settled.
    ///
    /// Falls back to the whole text when that leaves nothing, since reading a
    /// quoted-only draft's direction beats reading an empty string's.
    static func authoredPortion(of text: String) -> String {
        let body = QuotedRegion.split(Signature.split(text).body).body
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : body
    }
}
