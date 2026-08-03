import Foundation

/// Catches the recipient that is one or two keystrokes away from somebody the
/// account actually mails — `@gmial.com`, a transposed name, a doubled letter.
///
/// The corpus is `RecipientSuggestions.candidates` (the participants of every
/// thread summary already loaded locally), so this needs no new index, no new
/// fetch, and no new store: the same history that powers autocomplete is what
/// decides whether a typed address looks like a near-miss of a real one.
///
/// **Nothing is ever changed silently.** The output is a suggestion the view
/// offers; substituting a recipient behind the user's back would be a far worse
/// defect than the typo it fixes.
public enum LookalikeAddress {
    /// A typed address and the frequently-used contact it probably meant.
    public struct Match: Equatable, Sendable {
        public let typed: MailAddress
        public let suggestion: MailAddress
        /// Damerau-Levenshtein distance between the two addresses.
        public let distance: Int

        public init(typed: MailAddress, suggestion: MailAddress, distance: Int) {
            self.typed = typed; self.suggestion = suggestion; self.distance = distance
        }
    }

    /// How many loaded threads a candidate must appear in before it is treated
    /// as "frequently used" and therefore authoritative enough to correct a
    /// typed address against.
    ///
    /// One shared thread is not a relationship — it is very often a mailing
    /// list, a no-reply sender, or a one-off cc. Correcting a deliberate new
    /// recipient towards a stranger the account was cc'd on once would be worse
    /// than the typo.
    public static let frequencyThreshold = 2

    /// The near-misses among `addresses`.
    ///
    /// An address that is an EXACT (case-insensitive) match of any candidate —
    /// frequent or not — is never flagged: the account has demonstrably mailed
    /// it, so it is real regardless of what it resembles.
    public static func matches(in addresses: [MailAddress],
                               candidates: [RecipientSuggestions.Candidate]) -> [Match] {
        let known = Set(candidates.map { $0.address.email.lowercased() })
        let frequent = candidates.filter { $0.frequency >= frequencyThreshold }
        guard !frequent.isEmpty else { return [] }

        var results: [Match] = []
        for address in addresses {
            let typed = address.email.lowercased()
            guard !known.contains(typed) else { continue }
            var best: Match?
            for candidate in frequent {
                let other = candidate.address.email.lowercased()
                let distance = editDistance(typed, other)
                guard isPlausibleTypo(distance: distance, typed: typed, known: other) else { continue }
                if best == nil || distance < best!.distance {
                    best = Match(typed: address, suggestion: candidate.address, distance: distance)
                }
            }
            if let best { results.append(best) }
        }
        return results
    }

    /// Whether `distance` between two addresses is small enough, RELATIVE to
    /// their length, to be a typo rather than a different person.
    ///
    /// A flat "distance <= 2" flags `a@x.com` against `b@x.com` and every other
    /// pair of short unrelated addresses. The length gate is what stops that:
    /// two edits are only ever credible on an address long enough that two
    /// edits are a small fraction of it.
    static func isPlausibleTypo(distance: Int, typed: String, known: String) -> Bool {
        guard distance > 0 else { return false }
        let shortest = min(typed.count, known.count)
        guard shortest >= 8 else { return false }
        return distance <= (shortest >= 14 ? 2 : 1)
    }

    /// Damerau-Levenshtein distance (insertion, deletion, substitution, and
    /// ADJACENT TRANSPOSITION).
    ///
    /// The transposition case is the entire point: `gmial.com` for `gmail.com`
    /// and `Sahra` for `Sarah` are single transpositions, which plain
    /// Levenshtein scores as two edits — enough to fall outside a tight
    /// threshold and miss the two most common real typos.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        // Three rolling rows: transposition needs the row before the previous.
        var twoBack = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,        // deletion
                                 current[j - 1] + 1,     // insertion
                                 previous[j - 1] + cost) // substitution
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], twoBack[j - 2] + 1)
                }
            }
            twoBack = previous
            previous = current
        }
        return previous[b.count]
    }
}
