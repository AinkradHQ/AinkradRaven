import Foundation

/// Offers a subject when the field is empty, from the first line of the body.
///
/// Offered, never applied. An auto-filled subject is a message sent with a
/// subject the user never read — and the first line of a mail is very often a
/// greeting, which is the worst possible subject.
public enum SubjectSuggestion {
    /// Longest subject offered. RFC 5322's soft line limit is 78 octets and a
    /// subject longer than that is unreadable in every mail list anyway.
    static let maxLength = 72

    /// The suggestion, or `nil` when the body offers nothing usable.
    ///
    /// Skips greetings, quoted lines, and the attribution/signature regions;
    /// takes the first line of real content, collapses its whitespace and trims
    /// trailing punctuation. Truncation happens at a word boundary with an
    /// ellipsis, never mid-word.
    public static func suggest(from bodyText: String) -> String? {
        let authored = QuotedRegion.split(Signature.split(bodyText).body).body
        for rawLine in authored.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !line.isEmpty, !line.hasPrefix(">"), !isGreeting(line) else { continue }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!-—–"))
            guard !trimmed.isEmpty else { continue }
            return truncate(trimmed)
        }
        return nil
    }

    /// Whether a line is only a salutation. Matched in both scripts the user
    /// writes, and only when the WHOLE line is one — "Hi Bea, about the invoice"
    /// is a perfectly good subject line and must not be skipped.
    static func isGreeting(_ line: String) -> Bool {
        let core = line
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!:؛،"))
            .lowercased()
        let arabic = AttachmentIntent.normalizedArabic(core)
        let salutations = ["hi", "hey", "hello", "dear", "good morning", "good afternoon",
                           "good evening", "greetings", "morning"]
        let arabicSalutations = ["السلام عليكم", "اهلا", "مرحبا", "صباح الخير", "مساء الخير", "تحيه"]
        if salutations.contains(core) { return true }
        if arabicSalutations.contains(arabic) { return true }
        // "Hi Bea" / "Dear Bea" — a salutation plus a name and nothing else.
        let words = core.split(separator: " ")
        if words.count == 2, salutations.contains(String(words[0])) { return true }
        return false
    }

    static func truncate(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let cut = text.prefix(maxLength)
        if let space = cut.lastIndex(of: " ") {
            return cut[cut.startIndex..<space] + "…"
        }
        return cut + "…"
    }
}
