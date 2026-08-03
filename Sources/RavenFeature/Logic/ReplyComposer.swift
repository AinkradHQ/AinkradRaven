import Foundation

/// Builds the `OutgoingMessage` for Reply / Reply-all / Forward on the Thread
/// surface. Pure and synchronous — the body text of the message being
/// replied to must already be loaded (`ThreadSurface` only offers these
/// actions once a message's body has loaded), so this never touches the
/// network or the store itself.
public enum ReplyComposer {
    public enum Mode: Equatable, Sendable {
        case reply, replyAll, forward
    }

    /// - Parameters:
    ///   - thread: the thread being replied to/forwarded from.
    ///   - lastMessage: the message the reply quotes — always the thread's
    ///     most recent message, which is what a mail client's own "Reply"
    ///     addresses and quotes.
    ///   - lastMessageBody: that message's plain-text body, already loaded.
    ///   - ownAddress: the signed-in account's own address, excluded from a
    ///     reply-all so the account never mails itself.
    public static func compose(mode: Mode, thread: MailThread, lastMessage: MailMessage,
                               lastMessageBody: String, ownAddress: String?) -> OutgoingMessage {
        OutgoingMessage(
            to: recipients(mode: mode, lastMessage: lastMessage, ownAddress: ownAddress),
            subject: prefixedSubject(thread.subject, isForward: mode == .forward),
            bodyText: quoteBody(mode: mode, message: lastMessage, bodyText: lastMessageBody),
            inReplyToMessageID: mode == .forward ? nil : lastMessage.rfc822MessageID,
            threadID: mode == .forward ? nil : thread.id)
    }

    /// Reply: the sender only. Reply-all: sender + every other participant
    /// (original To/Cc), de-duplicated by address and with `ownAddress`
    /// EXCLUDED — replying-all must never queue a message addressed to the
    /// account's own mailbox. Forward: nobody; the user fills in a fresh
    /// recipient.
    static func recipients(mode: Mode, lastMessage: MailMessage,
                           ownAddress: String?) -> [MailAddress] {
        switch mode {
        case .forward:
            return []
        case .reply:
            return lastMessage.from.map { [$0] } ?? []
        case .replyAll:
            var seen = Set<String>()
            var result: [MailAddress] = []
            let own = ownAddress?.lowercased()
            for address in ([lastMessage.from].compactMap { $0 } + lastMessage.to + lastMessage.cc) {
                let key = address.email.lowercased()
                guard seen.insert(key).inserted else { continue }
                guard key != own else { continue }
                result.append(address)
            }
            return result
        }
    }

    /// Strips ANY number of leading `Re:`/`Fwd:`/`Fw:` prefixes (case
    /// insensitive, whatever whitespace) before adding exactly one — this is
    /// what collapses `Re: Re: hello` into `Re: hello` instead of stacking a
    /// second prefix on top of the first, and what lets forwarding an
    /// already-forwarded subject collapse the same way. Only the ASCII prefix tokens
    /// are matched; the remainder of the subject (including non-ASCII text,
    /// e.g. Arabic) is passed through untouched.
    static func prefixedSubject(_ subject: String, isForward: Bool) -> String {
        var stripped = subject
        let pattern = "^\\s*(re|fwd?)\\s*:\\s*"
        while let range = stripped.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            stripped.removeSubrange(range)
        }
        let prefix = isForward ? "Fwd: " : "Re: "
        return prefix + stripped
    }

    /// Conventional attribution line + `> `-prefixed quoted lines — the exact
    /// shape `QuoteTrimmer.split` already parses via its `"On .+wrote:"`
    /// pattern, so a reply composed here round-trips back through that same
    /// trimmer when the recipient's own client renders it.
    static func quoteBody(mode: Mode, message: MailMessage, bodyText: String) -> String {
        let attribution = "On \(attributionDate(message.date)), " +
            "\(message.from?.displayLabel ?? "someone") wrote:"
        let quoted = bodyText
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\n\n" + attribution + "\n" + quoted
    }

    private static func attributionDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
