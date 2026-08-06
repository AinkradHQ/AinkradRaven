import Foundation

/// Autocomplete source for Compose's To/Cc chip fields — scans the participants
/// of every thread summary the local month index shards have loaded
/// (`ThreadSummary.participants`) and ranks candidates by how often, and how
/// recently, the account has mailed them.
///
/// Deliberately separate from `ThreadSearch`: that type's `from:` token is a
/// fixed decision to match ONLY the address (see its own documentation), while
/// typing a name into Compose ("Bea") must surface "Bea Smith <bea@x.com>" —
/// an address-only match would never find it. Both are correct for what they
/// each do; neither should be bent to cover the other's job.
public enum RecipientSuggestions {
    /// One person the account has exchanged mail with, aggregated across every
    /// thread summary that mentions them.
    public struct Candidate: Equatable, Sendable {
        public let address: MailAddress
        /// Number of loaded threads this address appears as a participant of.
        public let frequency: Int
        /// The most recent `lastMessageDate` of any thread this address
        /// participated in.
        public let mostRecent: Date

        public init(address: MailAddress, frequency: Int, mostRecent: Date) {
            self.address = address; self.frequency = frequency; self.mostRecent = mostRecent
        }
    }

    /// Builds one `Candidate` per distinct address (case-insensitive) across
    /// `summaries`. When the same address appears with different display names
    /// over time, the name attached to the most recent thread wins — an old
    /// nickname should not outlive a more recent, presumably more current, one.
    public static func candidates(from summaries: [ThreadSummary]) -> [Candidate] {
        struct Accumulator { var address: MailAddress; var frequency: Int; var mostRecent: Date }
        var byEmail: [String: Accumulator] = [:]
        for summary in summaries {
            for participant in summary.participants {
                let key = participant.email.lowercased()
                if var existing = byEmail[key] {
                    existing.frequency += 1
                    if summary.lastMessageDate > existing.mostRecent {
                        existing.mostRecent = summary.lastMessageDate
                        existing.address = participant
                    }
                    byEmail[key] = existing
                } else {
                    byEmail[key] = Accumulator(address: participant, frequency: 1,
                                               mostRecent: summary.lastMessageDate)
                }
            }
        }
        return byEmail.values.map { Candidate(address: $0.address, frequency: $0.frequency,
                                              mostRecent: $0.mostRecent) }
    }

    /// Candidates whose address OR display name contains `query`
    /// (case-insensitive), ranked by frequency first and recency second —
    /// NOT alphabetically. An empty query returns every candidate, ranked the
    /// same way, so the field can show "recent people" before anything is typed.
    public static func match(_ query: String, in candidates: [Candidate]) -> [Candidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = needle.isEmpty ? candidates : candidates.filter {
            $0.address.email.lowercased().contains(needle)
                || ($0.address.name?.lowercased().contains(needle) ?? false)
        }
        return filtered.sorted {
            if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
            return $0.mostRecent > $1.mostRecent
        }
    }
}
