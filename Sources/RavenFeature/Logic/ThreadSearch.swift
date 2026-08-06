import Foundation

public struct ThreadQuery: Equatable, Sendable {
    public var terms: [String] = []
    public var from: [String] = []
    public var labels: [String] = []
    public var unreadOnly = false
    public var starredOnly = false
}

/// Search over the loaded window only. Archive-wide search is a provider call —
/// this never pretends to cover mail the store has not seen.
public enum ThreadSearch {
    public static func parse(_ query: String) -> ThreadQuery {
        var parsed = ThreadQuery()
        for token in query.split(separator: " ").map(String.init) where !token.isEmpty {
            let lowered = token.lowercased()
            if lowered.hasPrefix("from:") {
                let value = String(token.dropFirst(5)).lowercased()
                if !value.isEmpty { parsed.from.append(value) }
            } else if lowered.hasPrefix("label:") {
                // Compared case-insensitively against labelIDs at match time, so store lowercased.
                let value = String(token.dropFirst(6)).lowercased()
                if !value.isEmpty { parsed.labels.append(value) }
            } else if lowered == "is:unread" {
                parsed.unreadOnly = true
            } else if lowered == "is:starred" {
                parsed.starredOnly = true
            } else {
                parsed.terms.append(lowered)
            }
        }
        return parsed
    }

    public static func match(_ summaries: [ThreadSummary], query: String) -> [ThreadSummary] {
        let parsed = parse(query)
        return summaries.filter { matches($0, parsed) }
    }

    private static func matches(_ summary: ThreadSummary, _ query: ThreadQuery) -> Bool {
        if query.unreadOnly && summary.unreadCount == 0 { return false }
        if query.starredOnly && !summary.isStarred { return false }
        let loweredLabels = Set(summary.labelIDs.map { $0.lowercased() })
        for label in query.labels where !loweredLabels.contains(label) { return false }
        for needle in query.from {
            let hit = summary.participants.contains { $0.email.lowercased().contains(needle) }
            if !hit { return false }
        }
        for term in query.terms {
            let haystack = (summary.subject + " " + summary.snippet).lowercased()
            if !haystack.contains(term) { return false }
        }
        return true
    }
}
