import Foundation
import AinkradAppKit

/// One user-authored filter rule: an ordered list of conditions (ALL must
/// match — AND, not OR, mirroring `ThreadSearch`'s existing convention) and
/// one `ThreadAction` to take when they do. Rules themselves are ordered
/// (see `RuleSet`) and each can stop later rules from running against the
/// same thread, exactly like a traditional mail filter list.
///
/// The action is the EXISTING `ThreadAction` — never a fourth mutation path.
/// `RuleEngine.apply` enqueues through the same `ThreadMutationApplier`/
/// `Outbox` surface `RavenViewModel` and `RavenMCPOperations` already share,
/// so a rule's archive/star/label behaves identically to a human doing it by
/// hand, and can never drift into calling a provider directly.
public struct MailRule: Codable, Equatable, Identifiable, Sendable {
    public enum ConditionField: String, Codable, Sendable, CaseIterable {
        case sender, subject, label
    }

    /// A single "field CONTAINS text" test, case-insensitively. Deliberately
    /// this simple (no regex, no headers) — the task calls for sender/
    /// subject/label matching, not a general expression language.
    public struct Condition: Codable, Equatable, Sendable {
        public var field: ConditionField
        public var contains: String

        public init(field: ConditionField, contains: String) {
            self.field = field
            self.contains = contains
        }

        /// An empty `contains` matches nothing — an unfinished condition in
        /// the editor must not silently become "matches everything", which
        /// for an archive/trash action would be destructive.
        public func matches(_ summary: ThreadSummary) -> Bool {
            let needle = contains.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return false }
            switch field {
            case .sender:
                return summary.participants.contains {
                    $0.email.lowercased().contains(needle)
                        || ($0.name?.lowercased().contains(needle) ?? false)
                }
            case .subject:
                return summary.subject.lowercased().contains(needle)
            case .label:
                return summary.labelIDs.contains { $0.lowercased().contains(needle) }
            }
        }
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var conditions: [Condition]
    public var action: ThreadAction
    /// When true, a thread this rule matched is not tested against any rule
    /// after it in the ordered list — the traditional mail-filter "stop
    /// processing more rules" flag.
    public var stopProcessing: Bool

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true,
               conditions: [Condition] = [], action: ThreadAction, stopProcessing: Bool = false) {
        self.id = id; self.name = name; self.isEnabled = isEnabled
        self.conditions = conditions; self.action = action; self.stopProcessing = stopProcessing
    }

    /// A disabled rule, or one with no conditions at all, never matches — an
    /// empty condition list is not "matches everything" (that would make a
    /// freshly-created, not-yet-configured rule immediately start archiving
    /// every new arrival).
    public func matches(_ summary: ThreadSummary) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }
        return conditions.allSatisfy { $0.matches(summary) }
    }
}

/// The persisted, ordered rule list — one document, since these are
/// preferences, not secrets (see `DocumentKeys.rules`). Order is the array
/// order; there is no separate priority field to keep in sync with it.
public struct RuleSet: Codable, Equatable, Sendable {
    public var rules: [MailRule]
    public init(rules: [MailRule] = []) { self.rules = rules }

    public static func load(documents: PluginDocumentStore) -> RuleSet {
        guard let data = documents.data(forKey: DocumentKeys.rules),
              let decoded = try? JSONDecoder().decode(RuleSet.self, from: data)
        else { return RuleSet() }
        return decoded
    }

    public func save(documents: PluginDocumentStore) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        documents.setData(data, forKey: DocumentKeys.rules)
    }

    /// How many of `summaries` this ONE rule (in isolation, ignoring
    /// ordering/stop-processing against other rules) would currently match —
    /// the rule editor's "matches N of your recent threads" preview, so a
    /// rule that would e.g. archive everything is legible before saving.
    public static func previewCount(_ rule: MailRule, against summaries: [ThreadSummary]) -> Int {
        summaries.filter { rule.matches($0) }.count
    }
}
