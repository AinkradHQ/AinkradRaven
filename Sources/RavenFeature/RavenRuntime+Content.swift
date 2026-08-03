import Foundation
import AinkradAppKit

/// On-demand content fetches, and the thread-reply send path.
///
/// What these share, and why they are one file: each resolves the owning
/// account from the thread rather than guessing at "the" account, then goes
/// through that account's own provider. With several mailboxes connected, every
/// one of them is a place where guessing would reach the wrong server or mail
/// the user their own address, so they are worth reading next to each other.
///
/// Both fetches run off the main actor via `Task.detached` and neither writes
/// bytes to a cache directory.
extension RavenRuntime {

    // MARK: Bodies

    /// Returns the cached body if the store already has one, otherwise fetches
    /// it from the provider. The fetch (and the HTML-to-plain-text sanitizing
    /// it triggers inside `GmailMapping.body`, which the brief clocks at
    /// ~0.5s on a ~1MB body) runs off the main actor via `Task.detached` —
    /// this method is `async` precisely so callers await it rather than
    /// blocking the UI while it runs.
    /// The account is resolved from the message's own thread, so with several
    /// accounts connected a body is fetched by the mailbox it actually belongs
    /// to — and cached under that same account, so sign-out purges it.
    public func loadBody(for message: MailMessage) async -> MessageBody? {
        if let cached = store.body(messageID: message.id) { return cached }
        guard let accountID = store.thread(message.threadID)?.accountID,
              let provider = providers.provider(for: accountID) else { return nil }
        do {
            let body = try await Task.detached {
                try await provider.fetchBody(messageID: message.id)
            }.value
            // Attributed to the account that fetched it, so sign-out can purge
            // it even if this message's thread document never lands.
            try? store.saveBody(body, accountID: accountID)
            return body
        } catch {
            host.log.error("RavenRuntime.loadBody failed for \(message.id): \(error)")
            return nil
        }
    }

    // MARK: Attachments

    /// Fetches one attachment's bytes on demand, off the main actor — never
    /// written to a cache directory (see the task report's attachment-fetch
    /// notes). `nil` when there is no attached provider or the fetch fails;
    /// the caller (the Thread surface's chip tap handler) treats that as "try
    /// again later" rather than crashing.
    public func fetchAttachment(_ attachment: MailAttachment, messageID: String,
                                threadID: String) async -> Data? {
        guard let accountID = store.thread(threadID)?.accountID,
              let provider = providers.provider(for: accountID) else { return nil }
        do {
            return try await Task.detached {
                try await provider.fetchAttachment(messageID: messageID,
                                                    attachmentID: attachment.attachmentID)
            }.value
        } catch {
            host.log.error("RavenRuntime.fetchAttachment failed for \(attachment.attachmentID): \(error)")
            return nil
        }
    }

    // MARK: Compose (reply/reply-all/forward)

    /// The address of the account that owns `accountID`, so `ReplyComposer` can
    /// exclude it from a reply-all — never mail yourself. Takes the account
    /// explicitly (the caller reads it off the thread being replied to) rather
    /// than guessing at "the" account, which with several connected would
    /// exclude the wrong address and mail the user their own mailbox.
    public func ownAddress(for accountID: String) -> String? {
        store.accounts().first { $0.id == accountID }?.address
    }

    /// Sends a reply/reply-all/forward composed on the Thread surface through
    /// the exact same queue-drain-classify path every other send in this app
    /// uses (`SendAttempt`) — see that type's documentation for why sending
    /// lives in exactly one place. No draft id: a thread reply is not backed
    /// by a `DraftBox` entry.
    public func sendThreadReply(_ message: OutgoingMessage) async throws -> SendAttempt.Result {
        try await SendAttempt.send(message, draftID: nil, outbox: outbox, store: store,
                                   holdUntil: Date().addingTimeInterval(holdWindow),
                                   drain: drainOutbox)
    }
}
