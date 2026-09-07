import Foundation

/// Everything the composer knows about the draft on screen, reduced to the
/// facts the guards need. A value type with no view, no store and no clock, so
/// every rule below is testable by constructing one of these.
public struct ComposeDraftFacts: Equatable, Sendable {
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var bodyText: String
    public var hasAttachments: Bool
    /// The sending account's own address, for the self-recipient rule.
    public var ownAddress: String?
    /// Non-`nil` only for a reply-all: everybody who was on the original
    /// message (its From + To + Cc). Used to tell "reply-all as composed" from
    /// "reply-all with people the thread has never seen".
    public var replyAllParticipants: [MailAddress]?
    /// Frequently-mailed contacts, for the look-alike rule. Comes from
    /// `RecipientSuggestions.candidates` — the same corpus autocomplete uses.
    public var knownContacts: [RecipientSuggestions.Candidate]

    public init(to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                subject: String = "", bodyText: String = "", hasAttachments: Bool = false,
                ownAddress: String? = nil, replyAllParticipants: [MailAddress]? = nil,
                knownContacts: [RecipientSuggestions.Candidate] = []) {
        self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.bodyText = bodyText
        self.hasAttachments = hasAttachments
        self.ownAddress = ownAddress
        self.replyAllParticipants = replyAllParticipants
        self.knownContacts = knownContacts
    }

    /// Every addressee, in field order.
    public var allRecipients: [MailAddress] { to + cc + bcc }
}

/// A correction a finding can offer. The view renders it as a button; nothing
/// applies itself.
public enum ComposeCorrection: Equatable, Sendable {
    /// Put this text in the subject field.
    case useSubject(String)
    /// Replace a typo'd recipient with the contact it probably meant.
    case replaceRecipient(from: MailAddress, with: MailAddress)
    /// Drop the duplicated/self addresses `RecipientDedupe` identified.
    case dedupeRecipients
    /// Open the attachment picker.
    case attachFiles
}

/// One thing worth saying about the draft before it leaves.
public struct ComposeFinding: Equatable, Sendable, Identifiable {
    /// How hard this stops a send.
    public enum Severity: Equatable, Sendable {
        /// Shown inline. Never blocks; the user may simply not care.
        case notice
        /// Send pauses on a confirm dialog listing these. Deliberately a
        /// confirm and NEVER a block: a mail client that refuses to send an
        /// empty-subject message is a mail client that is wrong about the
        /// user's intent some of the time, and being wrong while also being
        /// unappealable is the failure mode to avoid.
        case confirm
    }

    public enum Kind: String, Equatable, Sendable {
        case attachmentIntentWithoutAttachment
        case emptySubject
        case emptyBody
        case duplicateRecipients
        case selfRecipient
        case wideReplyAll
        case replyAllAddsRecipients
        case lookalikeAddress
        case subjectSuggestion
    }

    public var id: String { kind.rawValue }
    public let kind: Kind
    public let severity: Severity
    public let message: String
    public let correction: ComposeCorrection?

    public init(kind: Kind, severity: Severity, message: String,
                correction: ComposeCorrection? = nil) {
        self.kind = kind; self.severity = severity
        self.message = message; self.correction = correction
    }
}

/// Every "stop the mistake before it leaves" rule, in one pure place.
///
/// The composer view renders `findings(for:)` and nothing else — it holds no
/// rule of its own, which is what makes each rule below fail a test if its
/// check is removed rather than quietly disappearing into a `body`.
public enum ComposeAdvice {
    /// How many recipients make a reply-all worth mentioning.
    ///
    /// Five, not three: a four-person project thread is a normal reply-all and
    /// warning on it teaches the user to dismiss the warning, at which point
    /// the twenty-person one goes out too.
    public static let wideReplyAllThreshold = 5

    public static func findings(for draft: ComposeDraftFacts) -> [ComposeFinding] {
        var out: [ComposeFinding] = []
        out.append(contentsOf: recipientFindings(draft))
        out.append(contentsOf: replyAllFindings(draft))
        out.append(contentsOf: contentFindings(draft))
        return out
    }

    /// The subset that pauses a send. Empty means Send goes straight through,
    /// exactly as it did before any of this existed.
    public static func confirmations(_ findings: [ComposeFinding]) -> [ComposeFinding] {
        findings.filter { $0.severity == .confirm }
    }

    // MARK: Recipients

    static func recipientFindings(_ draft: ComposeDraftFacts) -> [ComposeFinding] {
        var out: [ComposeFinding] = []
        let deduped = RecipientDedupe.apply(to: draft.to, cc: draft.cc, bcc: draft.bcc,
                                            ownAddress: draft.ownAddress)
        if !deduped.duplicates.isEmpty {
            let names = list(deduped.duplicates)
            out.append(ComposeFinding(
                kind: .duplicateRecipients, severity: .notice,
                message: "\(names) appears more than once across To, Cc and Bcc.",
                correction: .dedupeRecipients))
        }
        if !deduped.selfAddressed.isEmpty {
            out.append(ComposeFinding(
                kind: .selfRecipient, severity: .notice,
                message: "You are on this message's recipient list. You will get a copy in " +
                         "Sent either way.",
                correction: .dedupeRecipients))
        }
        // Look-alikes: every field, since a Bcc typo is the one nobody sees.
        let lookalikes = LookalikeAddress.matches(in: draft.allRecipients,
                                                  candidates: draft.knownContacts)
        if let first = lookalikes.first {
            out.append(ComposeFinding(
                kind: .lookalikeAddress, severity: .confirm,
                message: "\(first.typed.email) is \(first.distance == 1 ? "one character" : "two characters") " +
                         "away from \(first.suggestion.email), who you mail often. Did you mean them?",
                correction: .replaceRecipient(from: first.typed, with: first.suggestion)))
        }
        return out
    }

    // MARK: Reply-all

    static func replyAllFindings(_ draft: ComposeDraftFacts) -> [ComposeFinding] {
        guard let original = draft.replyAllParticipants else { return [] }
        var out: [ComposeFinding] = []
        let recipientCount = draft.to.count + draft.cc.count + draft.bcc.count
        if recipientCount > wideReplyAllThreshold {
            out.append(ComposeFinding(
                kind: .wideReplyAll, severity: .confirm,
                message: "This reply goes to \(recipientCount) people. Reply-all sends it to " +
                         "everyone on the thread, not just the sender."))
        }
        // Anyone in the recipient list who was never on the original message.
        // Adding someone to a reply-all forwards the whole quoted conversation
        // to a person who was not part of it — the version of this mistake that
        // actually leaks information rather than just annoying people.
        let known = Set(original.map { $0.email.lowercased() }
            + [draft.ownAddress?.lowercased()].compactMap { $0 })
        let added = draft.allRecipients.filter { !known.contains($0.email.lowercased()) }
        if !added.isEmpty {
            out.append(ComposeFinding(
                kind: .replyAllAddsRecipients, severity: .confirm,
                message: "\(list(added)) \(added.count == 1 ? "was" : "were") not on the original " +
                         "thread, and the quoted conversation below goes to them too."))
        }
        return out
    }

    // MARK: Content

    static func contentFindings(_ draft: ComposeDraftFacts) -> [ComposeFinding] {
        var out: [ComposeFinding] = []
        let subjectIsEmpty = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let bodyIsEmpty = QuotedRegion.split(Signature.split(draft.bodyText).body).body
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !draft.hasAttachments, AttachmentIntent.claimsAttachment(in: draft.bodyText) {
            out.append(ComposeFinding(
                kind: .attachmentIntentWithoutAttachment, severity: .confirm,
                message: "Your message mentions an attachment, but nothing is attached.",
                correction: .attachFiles))
        }
        if subjectIsEmpty {
            out.append(ComposeFinding(
                kind: .emptySubject, severity: .confirm,
                message: "This message has no subject."))
            if let suggestion = SubjectSuggestion.suggest(from: draft.bodyText) {
                out.append(ComposeFinding(
                    kind: .subjectSuggestion, severity: .notice,
                    message: "Use “\(suggestion)” as the subject?",
                    correction: .useSubject(suggestion)))
            }
        }
        if bodyIsEmpty {
            out.append(ComposeFinding(
                kind: .emptyBody, severity: .confirm,
                message: "This message has no body text."))
        }
        return out
    }

    static func list(_ addresses: [MailAddress]) -> String {
        let labels = addresses.map { $0.email }
        switch labels.count {
        case 0: return ""
        case 1: return labels[0]
        case 2: return "\(labels[0]) and \(labels[1])"
        default:
            // `default:` here implies count >= 3, so `labels.last` cannot be nil —
            // made total anyway so no future reader has to re-derive that.
            guard let last = labels.last else { return "" }
            return labels.dropLast().joined(separator: ", ") + " and " + last
        }
    }
}
