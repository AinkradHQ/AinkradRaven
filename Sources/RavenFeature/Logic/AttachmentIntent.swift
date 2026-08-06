import Foundation

/// "You said attached but attached nothing" — the single most common
/// self-inflicted mail mistake, detected from the body text.
///
/// Two things make this non-trivial and are the reason it is a type rather
/// than a `contains("attached")`:
///
/// 1. **The quoted original does not count.** In a reply, the person being
///    replied to very often wrote "see attached" — firing on their words would
///    warn on almost every reply to a mail that had an attachment, and a
///    warning that cries wolf is worse than none. Only the newly-typed portion
///    is scanned, via the existing `Signature`/`QuotedRegion` splits.
/// 2. **This user writes Arabic.** Matching only the English word means the
///    guard is silently absent for half of what they send. Arabic is matched
///    by *root*, after normalising the orthographic variation that makes a
///    literal string match useless — hamza forms (أ إ آ ٱ → ا), alef maksura
///    (ى → ي), teh marbuta (ة → ه), tatweel, and the combining harakat that
///    may or may not be typed.
public enum AttachmentIntent {
    /// English needles. Substring matches on a lowercased body, chosen to be
    /// phrases rather than bare words wherever the bare word is ambiguous:
    /// "attach" alone matches "attachment-free" and "unattached", while
    /// "attached"/"attaching"/"attachment" in a composed mail essentially
    /// always mean a file.
    static let englishNeedles = [
        "attached", "attaching", "attachment", "attachments",
        "enclosed", "enclosing", "i've enclosed",
        "see the file", "the file below", "find the file",
    ]

    /// Arabic needles, expressed against the NORMALISED form (see
    /// `normalizedArabic`). Roots, not inflections:
    ///
    /// - `مرفق` covers مرفق، المرفق، مرفقات، المرفقات، بالمرفق، مرفقة، مُرفَق
    /// - `ارفق` covers أرفقت، ارفقت، أرفقنا، سأرفق، ارفقلك
    /// - `ملحق` covers الملحق، ملحقات (used for "appendix/attachment" too)
    /// - `تجدون طيه` / `طياته` — the formal "herewith" construction
    static let arabicNeedles = [
        "مرفق", "ارفق", "ملحق", "طيه", "طياته", "الملف المرسل",
    ]

    /// Whether `bodyText` claims a file is attached.
    ///
    /// Scans only the authored portion, so a quoted "please find attached"
    /// from the correspondent cannot trigger it.
    public static func claimsAttachment(in bodyText: String) -> Bool {
        // Deliberately NOT `BaseTextDirection.authoredPortion`, which falls back
        // to the whole text when the authored part is empty. That fallback is
        // right for picking a layout direction and wrong here: a reply with
        // nothing typed yet must not inherit the quoted original's claim.
        let typed = QuotedRegion.split(Signature.split(bodyText).body).body
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let lowered = typed.lowercased()
        if englishNeedles.contains(where: { lowered.contains($0) }) { return true }
        let arabic = normalizedArabic(typed)
        return arabicNeedles.contains(where: { arabic.contains($0) })
    }

    /// Collapses the Arabic orthographic variation that defeats literal
    /// matching. Nothing here is language-aware beyond character folding — it
    /// is deliberately mechanical so it cannot mangle text in another script.
    static func normalizedArabic(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // Combining harakat, superscript alef, and the Quranic marks a
            // keyboard may or may not emit. Dropped entirely.
            case 0x064B...0x065F, 0x0670, 0x06D6...0x06ED:
                continue
            // Tatweel (kashida) — pure typographic stretching.
            case 0x0640:
                continue
            // Hamza-bearing and wasla alefs fold to bare alef.
            case 0x0622, 0x0623, 0x0625, 0x0671:
                out.append(Unicode.Scalar(0x0627)!)
            // Alef maksura folds to yeh.
            case 0x0649:
                out.append(Unicode.Scalar(0x064A)!)
            // Teh marbuta folds to heh.
            case 0x0629:
                out.append(Unicode.Scalar(0x0647)!)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }
}
