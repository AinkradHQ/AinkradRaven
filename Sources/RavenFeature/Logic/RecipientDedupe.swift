import Foundation

/// Normalises the three recipient fields into what should actually be sent.
///
/// Two rules, both of which produce a *visible* duplicate the moment Bcc
/// exists: the same person can now be typed into three fields, and until Bcc
/// existed the only way to mail yourself twice was To + Cc.
///
/// **This does not duplicate `ReplyComposer`.** `ReplyComposer.recipients`
/// already de-duplicates the original thread's participants and already removes
/// `ownAddress` from a reply-all, and that rule stays there — it is the only
/// place that knows a reply-all's recipient list is *derived* rather than
/// typed. What it cannot cover is what the user then types by hand into To, Cc
/// or the new Bcc field, or a draft loaded from `create_draft`, which is what
/// this covers. The reply-all path therefore passes through here as a no-op,
/// which is exactly the behaviour a second implementation of the same rule
/// should have.
public enum RecipientDedupe {
    /// The three fields after de-duplication.
    public struct Result: Equatable, Sendable {
        public let to: [MailAddress]
        public let cc: [MailAddress]
        public let bcc: [MailAddress]
        /// Addresses dropped because they appeared more than once.
        public let duplicates: [MailAddress]
        /// Addresses dropped because they are the account's own.
        public let selfAddressed: [MailAddress]

        public var changedAnything: Bool { !duplicates.isEmpty || !selfAddressed.isEmpty }
    }

    /// De-duplicates case-insensitively across all three fields at once and
    /// removes `ownAddress`.
    ///
    /// Field precedence is To > Cc > Bcc, and it is not arbitrary: keeping the
    /// *most* visible occurrence is the only choice that cannot silently
    /// downgrade a named recipient into a blind copy. Order within a field is
    /// preserved — a recipient list is something the user arranged.
    ///
    /// `ownAddress` is removed from Cc and Bcc but **kept in To**: "mail this to
    /// myself" is a real, deliberate thing to do, and it is unambiguous when
    /// the account's own address is the only thing in To. It is removed from To
    /// only when To has other recipients as well, where it is a reply-all
    /// artefact rather than an intention.
    public static func apply(to: [MailAddress], cc: [MailAddress], bcc: [MailAddress],
                             ownAddress: String?) -> Result {
        let own = ownAddress?.lowercased()
        var seen = Set<String>()
        var duplicates: [MailAddress] = []
        var selfAddressed: [MailAddress] = []

        let deliberateSelfSend = to.count == 1 && cc.isEmpty
            && to.first.map { $0.email.lowercased() == own } == true

        func filter(_ addresses: [MailAddress], isTo: Bool) -> [MailAddress] {
            var kept: [MailAddress] = []
            for address in addresses {
                let key = address.email.lowercased()
                guard seen.insert(key).inserted else {
                    duplicates.append(address)
                    continue
                }
                if key == own, !(isTo && deliberateSelfSend) {
                    selfAddressed.append(address)
                    continue
                }
                kept.append(address)
            }
            return kept
        }

        let keptTo = filter(to, isTo: true)
        let keptCc = filter(cc, isTo: false)
        let keptBcc = filter(bcc, isTo: false)
        return Result(to: keptTo, cc: keptCc, bcc: keptBcc,
                      duplicates: duplicates, selfAddressed: selfAddressed)
    }
}
