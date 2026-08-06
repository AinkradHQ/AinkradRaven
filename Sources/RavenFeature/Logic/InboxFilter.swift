import Foundation

/// What "in the inbox" means, in exactly one place.
///
/// `MailStore.summaries(accountID:months:)` returns every thread that landed
/// in a given month shard, regardless of label — that is deliberately a raw
/// index read, not an inbox view. Without a filter applied on top, the Inbox
/// list showed archived and trashed threads right alongside real inbox mail,
/// and — because `RavenViewModel`, `ThreadSearch`, and the MCP `search_mail`/
/// `unread_summary` tools each read `summaries` independently — a thread
/// archived from the UI could still show up as "in the inbox" to Sage, and
/// vice versa.
///
/// This is the one shared filter both the human surfaces and the agent tools
/// apply, so they cannot disagree about which threads count as inbox mail.
/// It does NOT gate `read_thread` or `MailStore.thread(_:)` — a thread that
/// has left the inbox is still fully readable by id; only the *list/search*
/// views that claim to represent "the inbox" apply this.
public enum InboxFilter {
    /// A thread counts as "in the inbox" when its stored labels canonically
    /// mean `.inbox` and mean neither `.trash` nor `.spam` — a backend can
    /// (rarely) leave the inbox marker on a message that was also moved to
    /// Trash/Spam, and a filter that checked inbox alone would still surface it.
    ///
    /// The labels are read through a `LabelVocabulary` rather than compared to
    /// Gmail's spelling, so the same filter is correct for a backend whose
    /// inbox is a folder rather than a label.
    public static func isInInbox(_ summary: ThreadSummary,
                                vocabulary: LabelVocabulary = defaultLabelVocabulary) -> Bool {
        let flags = vocabulary.flags(from: summary.labelIDs)
        return flags.contains(.inbox) && !flags.contains(.trash) && !flags.contains(.spam)
    }

    public static func apply(_ summaries: [ThreadSummary],
                            vocabulary: LabelVocabulary = defaultLabelVocabulary) -> [ThreadSummary] {
        summaries.filter { isInInbox($0, vocabulary: vocabulary) }
    }
}
