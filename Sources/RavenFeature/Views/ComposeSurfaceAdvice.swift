import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// `ComposeSurface`'s guard half: gathering the draft's facts, and applying a
/// correction the user pressed.
///
/// Split out purely to keep `ComposeSurface` under the 500-line cap, exactly as
/// `ComposeDraftAutosave` was. The members are `internal` rather than `private`
/// because an extension in a different file cannot see `private` ones; they are
/// still only reachable inside this module.
///
/// **No rule lives here.** Every decision about what counts as a mistake is in
/// `ComposeAdvice`, which is pure and tested. This file only reads the live
/// fields into a `ComposeDraftFacts` and writes back what the user asked for.
extension ComposeSurface {
    // MARK: Advice

    /// Everything the guards need, gathered from the live fields. Rebuilt per
    /// render, which is cheap — every rule in `ComposeAdvice` is a pure string
    /// or set operation over a handful of addresses.
    var draftFacts: ComposeDraftFacts {
        ComposeDraftFacts(
            to: ComposeValidation.validAddresses(toChips),
            cc: ComposeValidation.validAddresses(ccChips),
            bcc: ComposeValidation.validAddresses(bccChips),
            subject: subject,
            bodyText: bodyText,
            hasAttachments: !attachments.isEmpty,
            ownAddress: sendingAddress,
            replyAllParticipants: replyAllParticipants,
            knownContacts: suggestionCandidates)
    }

    var findings: [ComposeFinding] { ComposeAdvice.findings(for: draftFacts) }

    /// The address this message will actually leave from — the thread's account
    /// for a reply, the resolved From account otherwise. Not "the" account: with
    /// several connected, using the wrong one makes the self-recipient rule
    /// strip the wrong address.
    var sendingAddress: String? {
        if let thread = activeContext.thread {
            return runtime.ownAddress(for: thread.accountID)
        }
        return effectiveAccountID.flatMap { runtime.ownAddress(for: $0) }
    }

    /// Everyone who was on the message being replied to, for the reply-all
    /// rules. `nil` for anything that is not a reply-all, which is what makes
    /// `ComposeAdvice` skip those rules entirely.
    var replyAllParticipants: [MailAddress]? {
        guard case .reply(let mode, let reference) = activeContext, mode == .replyAll,
              let thread = runtime.store.thread(reference.threadID),
              let last = thread.messages.last else { return nil }
        return [last.from].compactMap { $0 } + last.to + last.cc
    }

    /// Applies a correction the user pressed. Every one of these is a user act;
    /// `ComposeAdvice` never mutates anything itself.
    func apply(_ correction: ComposeCorrection) {
        switch correction {
        case .useSubject(let text):
            subject = text
        case .replaceRecipient(let from, let with):
            let replacement = RecipientChip(raw: rfc5322(for: with))
            func swap(_ chips: inout [RecipientChip]) {
                for index in chips.indices
                where chips[index].address?.email.lowercased() == from.email.lowercased() {
                    chips[index] = replacement
                }
            }
            swap(&toChips); swap(&ccChips); swap(&bccChips)
        case .dedupeRecipients:
            let result = RecipientDedupe.apply(to: draftFacts.to, cc: draftFacts.cc,
                                               bcc: draftFacts.bcc, ownAddress: sendingAddress)
            // Only the VALID chips are rebuilt from the deduped result; an
            // invalid chip has no address to compare and must survive untouched
            // rather than being silently dropped by a tidy-up.
            func rebuild(_ chips: [RecipientChip], _ kept: [MailAddress]) -> [RecipientChip] {
                let keep = Set(kept.map { $0.email.lowercased() })
                return chips.filter { chip in
                    guard let email = chip.address?.email.lowercased() else { return true }
                    return keep.contains(email)
                }
            }
            toChips = rebuild(toChips, result.to)
            ccChips = rebuild(ccChips, result.cc)
            bccChips = rebuild(bccChips, result.bcc)
        case .attachFiles:
            attachments.append(contentsOf: ComposeAttachmentPicker.pick())
        }
    }

    /// Suggestion pool for both the To and Cc fields, rebuilt from whatever
    /// month shards the Inbox has already loaded (`RavenViewModel.summaries`).
    /// This never issues its own fetch — it only ranks what is already local.
    var suggestionCandidates: [RecipientSuggestions.Candidate] {
        RecipientSuggestions.candidates(from: runtime.model.summaries)
    }
}
