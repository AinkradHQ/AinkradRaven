import Foundation

/// Combining a freshly fetched thread with the copy already stored, for the one
/// case where a write is a PARTIAL view of a thread rather than the whole of it.
///
/// ## Why this exists, and why it is not simply how `upsertThread` behaves
///
/// A backfill walk pages one MAILBOX at a time. Any server may list one message in
/// two mailboxes — Gmail does it for every labelled message, and a plain IMAP
/// server does it whenever mail is copied — so the same thread is assembled twice,
/// in different pages, and written twice. `MailStore.upsertThread` replaces the
/// whole document, so the second write erases the first's labels: a thread
/// genuinely in the inbox ends up labelled with whichever mailbox was walked last
/// and disappears from the inbox list. That is the defect this type repairs, found
/// on a live account whose inbox rendered empty while the counter climbed past 400
/// for 212 real messages.
///
/// It is deliberately NOT folded into `upsertThread` itself, because for the delta
/// path replacement is exactly right and folding would be a bug. A delta says
/// "this thread changed, here it is in full", and a label REMOVAL is expressed by
/// the label's absence — archiving a Gmail thread returns it without `INBOX`.
/// Unioning there would put `INBOX` straight back and make archiving impossible.
/// So the rule is: **fold a partial view, replace a whole one.**
enum ThreadFolding {

    /// `fresh` with each message's `labelIDs` unioned with the stored copy's, and
    /// any stored message this fetch did not mention carried over.
    ///
    /// `stored == nil` — the ordinary first sync — returns `fresh` untouched.
    ///
    /// Only labels are unioned. Every other field comes from the fetch just
    /// performed, because that is the server's current answer: folding `isRead`
    /// would resurrect an unread state the user has since cleared.
    static func fold(_ fresh: MailThread, into stored: MailThread?) -> MailThread {
        guard let stored, !stored.messages.isEmpty else { return fresh }
        var storedByKey: [String: MailMessage] = [:]
        for message in stored.messages { storedByKey[key(message), default: message] = message }

        var merged = fresh.messages.map { message -> MailMessage in
            guard let previous = storedByKey.removeValue(forKey: key(message)) else { return message }
            var message = message
            message.labelIDs = Array(Set(message.labelIDs).union(previous.labelIDs)).sorted()
            // The id stays the FETCH's own, which is stable across runs because
            // `IMAPProvider.walkable` fixes the mailbox order — so the same mailbox
            // is always the last to write, and the locator always names a mailbox
            // the message is really in.
            return message
        }
        // Whatever this page did not mention is still real: the page covered one
        // mailbox, not the account. Dropping it would delete mail on every sync.
        merged.append(contentsOf: storedByKey.values)
        return MailThread(id: fresh.id, accountID: fresh.accountID,
                          messages: merged.sorted { ($0.date, $0.id) < ($1.date, $1.id) })
    }

    /// Messages are matched on the RFC 822 `Message-ID`, not on `MailMessage.id`,
    /// because an IMAP id is an `IMAPMessageLocator` and a locator is
    /// mailbox-scoped: the same message in two mailboxes has two ids and would
    /// otherwise be stored twice, showing the user one message as two.
    ///
    /// A message with no `Message-ID` falls back to its own id, so a
    /// `Message-ID`-less message copied between mailboxes stays two rows. With no
    /// stable identity from the server there is nothing to prove the two are the
    /// same message, and merging them on a guess would silently drop one.
    private static func key(_ message: MailMessage) -> String {
        message.rfc822MessageID.flatMap { $0.isEmpty ? nil : $0 } ?? message.id
    }
}
