import Foundation

/// Groups a flat list of messages into threads purely from `References`/
/// `In-Reply-To`, keyed by `Message-ID` — never by subject. Two unrelated
/// messages that happen to share a subject must NOT merge; a reply chain
/// whose subject drifts (a forward, an edited subject) must still merge, as
/// long as the `References`/`In-Reply-To` chain says so.
///
/// Provider-independent and reusable — the Apple Mail import is the first
/// consumer, but any provider whose backend does not thread server-side
/// (a future IMAP provider, per M2's plan) can reuse this rather than each
/// growing its own subject-matching heuristic.
public enum LocalThreading {
    /// One message as `LocalThreading` needs to see it — deliberately not
    /// `MailMessage`/`RFC822Message` themselves, so this stays usable from
    /// either a fully-imported `MailMessage` or a freshly parsed
    /// `RFC822Message` without either one depending on the other.
    public struct Node: Sendable {
        public let messageID: String
        public let references: [String]
        public let inReplyTo: String?

        public init(messageID: String, references: [String], inReplyTo: String?) {
            self.messageID = messageID; self.references = references; self.inReplyTo = inReplyTo
        }
    }

    /// Returns the input `messageIDs`, grouped into threads. Each output
    /// group is a set of message ids belonging to one thread, in no
    /// particular order. A message with no references and no id shared by
    /// any other message is its own singleton thread.
    ///
    /// Union-find over the id graph: every message is linked to its
    /// `In-Reply-To` and every id in `References` (when that id is itself a
    /// message present in this batch — an ancestor never seen locally does
    /// not, by itself, merge two OTHER messages that both cite it into one
    /// thread unless they are otherwise linked, since threading is meant to
    /// reflect an actual reply relationship this batch can see).
    public static func group(_ nodes: [Node]) -> [[String]] {
        var parent: [String: String] = [:]
        func find(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current { current = next }
            parent[id] = current
            return current
        }
        func union(_ a: String, _ b: String) {
            let rootA = find(a), rootB = find(b)
            guard rootA != rootB else { return }
            parent[rootA] = rootB
        }

        let present = Set(nodes.map(\.messageID))
        for node in nodes {
            parent[node.messageID] = parent[node.messageID] ?? node.messageID
            let linked = ([node.inReplyTo].compactMap { $0 } + node.references)
                .filter { present.contains($0) && $0 != node.messageID }
            for other in linked {
                parent[other] = parent[other] ?? other
                union(node.messageID, other)
            }
        }

        var groups: [String: [String]] = [:]
        for node in nodes {
            groups[find(node.messageID), default: []].append(node.messageID)
        }
        return Array(groups.values)
    }
}
