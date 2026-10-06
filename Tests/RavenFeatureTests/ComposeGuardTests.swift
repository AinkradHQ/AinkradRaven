import Foundation
import Testing

@testable import RavenFeature

/// The compose guards. Every rule has at least one test that fails if the
/// rule's own check is removed — which is the point of `ComposeAdvice` being a
/// pure type rather than conditions inside a `body`.
@Suite("ComposeAdvice — attachment intent")
struct AttachmentIntentTests {
    @Test("plain English attachment claims are detected")
    func english() {
        #expect(AttachmentIntent.claimsAttachment(in: "Please find attached the invoice."))
        #expect(AttachmentIntent.claimsAttachment(in: "See attached."))
        #expect(AttachmentIntent.claimsAttachment(in: "I'm attaching the deck now"))
        #expect(AttachmentIntent.claimsAttachment(in: "The attachment has the numbers."))
        #expect(AttachmentIntent.claimsAttachment(in: "Enclosed is the signed copy."))
    }

    @Test("a body with no attachment claim is not flagged")
    func noClaim() {
        #expect(!AttachmentIntent.claimsAttachment(in: "Thanks, that works for me."))
        #expect(!AttachmentIntent.claimsAttachment(in: ""))
        // The word alone in an unrelated sense must not fire. "attach" is not a
        // needle for exactly this reason.
        #expect(!AttachmentIntent.claimsAttachment(in: "I'll attach myself to that project."))
    }

    @Test("Arabic attachment claims are detected, in every common inflection")
    func arabic() {
        // مرفق root: attachment, the attachments, with the attachment, attached (f.)
        #expect(AttachmentIntent.claimsAttachment(in: "الملف مرفق بالرسالة"))
        #expect(AttachmentIntent.claimsAttachment(in: "تجد المرفقات في الأسفل"))
        #expect(AttachmentIntent.claimsAttachment(in: "الفاتورة مرفقة"))
        // أرفق root, with and without hamza — the two ways this is actually typed.
        #expect(AttachmentIntent.claimsAttachment(in: "أرفقت لك التقرير"))
        #expect(AttachmentIntent.claimsAttachment(in: "ارفقت لك التقرير"))
        // With harakat, which a fully-vowelled keyboard emits.
        #expect(AttachmentIntent.claimsAttachment(in: "الملف مُرفَق"))
        // The formal "herewith" construction.
        #expect(AttachmentIntent.claimsAttachment(in: "تجدون طيه العقد"))
    }

    @Test("an Arabic body with no attachment claim is not flagged")
    func arabicNoClaim() {
        #expect(!AttachmentIntent.claimsAttachment(in: "شكرا لك، سأراجع الموضوع غدا"))
    }

    @Test("a quoted 'see attached' from the correspondent does not fire")
    func quotedClaimIgnored() {
        // The whole reason this is not `body.contains("attached")`: replying to
        // a mail that HAD an attachment would otherwise warn every time.
        let reply = """
            Got it, thanks.

            On Jan 1, 2020 at 9:00 AM, Bea Smith wrote:
            > Please find attached the invoice.
            """
        #expect(!AttachmentIntent.claimsAttachment(in: reply))
    }

    @Test("a reply with nothing typed yet does not inherit the quote's claim")
    func emptyAuthoredPortion() {
        let reply = """


            On Jan 1, 2020 at 9:00 AM, Bea Smith wrote:
            > See attached.
            """
        #expect(!AttachmentIntent.claimsAttachment(in: reply))
    }

    @Test("the finding appears only when nothing is actually attached")
    func findingGatedOnAttachments() {
        var draft = ComposeDraftFacts(
            to: [MailAddress(email: "b@x.com")],
            subject: "Invoice",
            bodyText: "Please find attached the invoice.")
        #expect(
            ComposeAdvice.findings(for: draft)
                .contains { $0.kind == .attachmentIntentWithoutAttachment })
        draft.hasAttachments = true
        #expect(
            !ComposeAdvice.findings(for: draft)
                .contains { $0.kind == .attachmentIntentWithoutAttachment })
    }
}

@Suite("ComposeAdvice — empty subject and body")
struct ComposeEmptinessTests {
    private let recipient = [MailAddress(email: "bea@x.com")]

    @Test("an empty subject is a confirm, not a block")
    func emptySubject() {
        let draft = ComposeDraftFacts(to: recipient, subject: "   ", bodyText: "Body here.")
        let findings = ComposeAdvice.findings(for: draft)
        let subjectFinding = findings.first { $0.kind == .emptySubject }
        #expect(subjectFinding != nil)
        #expect(subjectFinding?.severity == .confirm)
        // Confirm, never block: `confirmations` is a list to show, and Send
        // remains pressable.
        #expect(ComposeAdvice.confirmations(findings).contains { $0.kind == .emptySubject })
    }

    @Test("an empty body is a confirm")
    func emptyBody() {
        let draft = ComposeDraftFacts(to: recipient, subject: "Hello", bodyText: "\n \n")
        let findings = ComposeAdvice.findings(for: draft)
        #expect(findings.contains { $0.kind == .emptyBody && $0.severity == .confirm })
    }

    @Test("a reply whose only content is the quoted original counts as empty")
    func quoteOnlyBodyIsEmpty() {
        let draft = ComposeDraftFacts(
            to: recipient, subject: "Re: Hello",
            bodyText: "\n\nOn Jan 1, 2020 at 9:00 AM, Bea Smith wrote:\n> Original.")
        #expect(ComposeAdvice.findings(for: draft).contains { $0.kind == .emptyBody })
    }

    @Test("a complete message produces no confirmations at all")
    func cleanDraft() {
        let draft = ComposeDraftFacts(
            to: recipient, subject: "Hello",
            bodyText: "This is the message.")
        #expect(ComposeAdvice.confirmations(ComposeAdvice.findings(for: draft)).isEmpty)
    }
}

@Suite("ComposeAdvice — subject suggestion")
struct SubjectSuggestionTests {
    @Test("the first real line becomes the suggestion")
    func firstLine() {
        #expect(
            SubjectSuggestion.suggest(from: "Invoice for March\n\nDetails follow.")
                == "Invoice for March")
    }

    @Test("a bare greeting line is skipped")
    func greetingSkipped() {
        #expect(
            SubjectSuggestion.suggest(from: "Hi Bea,\n\nThe invoice is late.")
                == "The invoice is late")
        #expect(SubjectSuggestion.suggest(from: "Hello\nAbout the contract") == "About the contract")
        // A greeting plus real content on the SAME line is a good subject and
        // must not be skipped.
        #expect(
            SubjectSuggestion.suggest(from: "Hi Bea, about the invoice")
                == "Hi Bea, about the invoice")
    }

    @Test("an Arabic greeting is skipped too")
    func arabicGreetingSkipped() {
        #expect(
            SubjectSuggestion.suggest(from: "السلام عليكم\nبخصوص الفاتورة")
                == "بخصوص الفاتورة")
    }

    @Test("a long first line truncates at a word boundary")
    func truncation() {
        let line = String(repeating: "alpha ", count: 30)
        let suggestion = SubjectSuggestion.suggest(from: line)
        #expect(suggestion != nil)
        #expect(suggestion!.count <= SubjectSuggestion.maxLength + 1)
        #expect(suggestion!.hasSuffix("…"))
        #expect(!suggestion!.contains("alph…"))
    }

    @Test("nothing is suggested from an empty or quote-only body")
    func nothingToSuggest() {
        #expect(SubjectSuggestion.suggest(from: "") == nil)
        #expect(SubjectSuggestion.suggest(from: "\n\n> quoted only") == nil)
    }

    @Test("the suggestion is OFFERED, never applied, and only when subject is empty")
    func offeredNotApplied() {
        let draft = ComposeDraftFacts(
            to: [MailAddress(email: "b@x.com")],
            subject: "", bodyText: "Invoice for March")
        let findings = ComposeAdvice.findings(for: draft)
        let suggestion = findings.first { $0.kind == .subjectSuggestion }
        #expect(suggestion?.severity == .notice)
        #expect(suggestion?.correction == .useSubject("Invoice for March"))
        // The draft itself is untouched — the whole contract of a correction.
        #expect(draft.subject.isEmpty)

        var filled = draft
        filled.subject = "Something"
        #expect(!ComposeAdvice.findings(for: filled).contains { $0.kind == .subjectSuggestion })
    }
}

@Suite("ComposeAdvice — reply-all")
struct ReplyAllGuardTests {
    private func address(_ n: Int) -> MailAddress { MailAddress(email: "p\(n)@x.com") }

    @Test("a wide reply-all is called out")
    func wideReplyAll() {
        let people = (1...7).map(address)
        let draft = ComposeDraftFacts(
            to: people, subject: "Re: Hi", bodyText: "Sure.",
            ownAddress: "me@x.com",
            replyAllParticipants: people)
        let finding = ComposeAdvice.findings(for: draft).first { $0.kind == .wideReplyAll }
        #expect(finding?.severity == .confirm)
        #expect(finding?.message.contains("7 people") == true)
    }

    @Test("a normal-sized reply-all is not called out")
    func narrowReplyAll() {
        let people = (1...4).map(address)
        let draft = ComposeDraftFacts(
            to: people, subject: "Re: Hi", bodyText: "Sure.",
            ownAddress: "me@x.com",
            replyAllParticipants: people)
        #expect(!ComposeAdvice.findings(for: draft).contains { $0.kind == .wideReplyAll })
    }

    @Test("a recipient who was not on the original thread is called out")
    func addedRecipient() {
        let original = [address(1), address(2)]
        let outsider = MailAddress(email: "outsider@y.com")
        let draft = ComposeDraftFacts(
            to: original, cc: [outsider], subject: "Re: Hi",
            bodyText: "Sure.", ownAddress: "me@x.com",
            replyAllParticipants: original)
        let finding = ComposeAdvice.findings(for: draft)
            .first { $0.kind == .replyAllAddsRecipients }
        #expect(finding?.severity == .confirm)
        #expect(finding?.message.contains("outsider@y.com") == true)
    }

    @Test("a Bcc'd outsider is called out too — the version nobody can see")
    func addedBccRecipient() {
        let original = [address(1)]
        let draft = ComposeDraftFacts(
            to: original, bcc: [MailAddress(email: "boss@y.com")],
            subject: "Re: Hi", bodyText: "Sure.",
            ownAddress: "me@x.com", replyAllParticipants: original)
        #expect(ComposeAdvice.findings(for: draft).contains { $0.kind == .replyAllAddsRecipients })
    }

    @Test("the account's own address is not treated as an outsider")
    func ownAddressIsNotAnOutsider() {
        let original = [address(1)]
        let draft = ComposeDraftFacts(
            to: original + [MailAddress(email: "me@x.com")],
            subject: "Re: Hi", bodyText: "Sure.",
            ownAddress: "me@x.com", replyAllParticipants: original)
        #expect(!ComposeAdvice.findings(for: draft).contains { $0.kind == .replyAllAddsRecipients })
    }

    @Test("neither reply-all rule fires on a message that is not a reply-all")
    func notAReplyAll() {
        let people = (1...9).map(address)
        // `replyAllParticipants` nil — a new message to nine people is a
        // mailing, not a mistake, and warning about it would be noise.
        let draft = ComposeDraftFacts(to: people, subject: "Hi", bodyText: "Hello all.")
        let findings = ComposeAdvice.findings(for: draft)
        #expect(!findings.contains { $0.kind == .wideReplyAll })
        #expect(!findings.contains { $0.kind == .replyAllAddsRecipients })
    }
}
