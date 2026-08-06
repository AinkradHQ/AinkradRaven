import Testing
import Foundation
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
        var draft = ComposeDraftFacts(to: [MailAddress(email: "b@x.com")],
                                      subject: "Invoice",
                                      bodyText: "Please find attached the invoice.")
        #expect(ComposeAdvice.findings(for: draft)
            .contains { $0.kind == .attachmentIntentWithoutAttachment })
        draft.hasAttachments = true
        #expect(!ComposeAdvice.findings(for: draft)
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
        let draft = ComposeDraftFacts(to: recipient, subject: "Hello",
                                      bodyText: "This is the message.")
        #expect(ComposeAdvice.confirmations(ComposeAdvice.findings(for: draft)).isEmpty)
    }
}

@Suite("ComposeAdvice — subject suggestion")
struct SubjectSuggestionTests {
    @Test("the first real line becomes the suggestion")
    func firstLine() {
        #expect(SubjectSuggestion.suggest(from: "Invoice for March\n\nDetails follow.")
            == "Invoice for March")
    }

    @Test("a bare greeting line is skipped")
    func greetingSkipped() {
        #expect(SubjectSuggestion.suggest(from: "Hi Bea,\n\nThe invoice is late.")
            == "The invoice is late")
        #expect(SubjectSuggestion.suggest(from: "Hello\nAbout the contract") == "About the contract")
        // A greeting plus real content on the SAME line is a good subject and
        // must not be skipped.
        #expect(SubjectSuggestion.suggest(from: "Hi Bea, about the invoice")
            == "Hi Bea, about the invoice")
    }

    @Test("an Arabic greeting is skipped too")
    func arabicGreetingSkipped() {
        #expect(SubjectSuggestion.suggest(from: "السلام عليكم\nبخصوص الفاتورة")
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
        let draft = ComposeDraftFacts(to: [MailAddress(email: "b@x.com")],
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

@Suite("RecipientDedupe")
struct RecipientDedupeTests {
    @Test("the same address in To and Cc is kept once, in To")
    func acrossFields() {
        let bea = MailAddress(email: "bea@x.com")
        let result = RecipientDedupe.apply(to: [bea], cc: [bea], bcc: [],
                                          ownAddress: "me@x.com")
        #expect(result.to == [bea])
        #expect(result.cc.isEmpty)
        #expect(result.duplicates == [bea])
    }

    @Test("To wins over Cc which wins over Bcc — never a silent downgrade to blind")
    func precedence() {
        let bea = MailAddress(email: "bea@x.com")
        let cal = MailAddress(email: "cal@x.com")
        let result = RecipientDedupe.apply(to: [], cc: [bea], bcc: [bea, cal],
                                          ownAddress: nil)
        #expect(result.cc == [bea])
        #expect(result.bcc == [cal])
    }

    @Test("case differences are the same person")
    func caseInsensitive() {
        let result = RecipientDedupe.apply(to: [MailAddress(email: "Bea@X.com")],
                                          cc: [MailAddress(email: "bea@x.com")],
                                          bcc: [], ownAddress: nil)
        #expect(result.cc.isEmpty)
        #expect(result.duplicates.count == 1)
    }

    @Test("the account's own address is removed from Cc and Bcc")
    func ownAddressRemoved() {
        let me = MailAddress(email: "me@x.com")
        let bea = MailAddress(email: "bea@x.com")
        let result = RecipientDedupe.apply(to: [bea], cc: [me], bcc: [], ownAddress: "me@x.com")
        #expect(result.cc.isEmpty)
        #expect(result.selfAddressed == [me])
    }

    @Test("mailing yourself deliberately is preserved")
    func deliberateSelfSend() {
        let me = MailAddress(email: "me@x.com")
        let result = RecipientDedupe.apply(to: [me], cc: [], bcc: [], ownAddress: "me@x.com")
        #expect(result.to == [me])
        #expect(result.selfAddressed.isEmpty)
    }

    @Test("order within a field is preserved")
    func orderPreserved() {
        let a = MailAddress(email: "a@x.com"), b = MailAddress(email: "b@x.com")
        let c = MailAddress(email: "c@x.com")
        let result = RecipientDedupe.apply(to: [c, a, b], cc: [], bcc: [], ownAddress: nil)
        #expect(result.to == [c, a, b])
    }

    @Test("ReplyComposer's reply-all output passes through unchanged")
    func replyAllIsAlreadyClean() {
        // The rule lives in ONE place. `ReplyComposer.recipients` already
        // de-duplicates and already drops `ownAddress`; this must therefore be a
        // no-op on its output, which is what proves the two are not fighting.
        let last = MailMessage(
            id: "m1", threadID: "t1",
            from: MailAddress(email: "bea@x.com"),
            to: [MailAddress(email: "me@x.com"), MailAddress(email: "cal@x.com")],
            cc: [MailAddress(email: "bea@x.com")],
            subject: "Hello", date: Date())
        let derived = ReplyComposer.recipients(mode: .replyAll, lastMessage: last,
                                              ownAddress: "me@x.com")
        let result = RecipientDedupe.apply(to: derived, cc: [], bcc: [], ownAddress: "me@x.com")
        #expect(result.to == derived)
        #expect(!result.changedAnything)
    }

    @Test("a duplicate produces a notice with a correction, not a block")
    func findingIsANotice() {
        let bea = MailAddress(email: "bea@x.com")
        let draft = ComposeDraftFacts(to: [bea], cc: [bea], subject: "S", bodyText: "B")
        let findings = ComposeAdvice.findings(for: draft)
        let finding = findings.first { $0.kind == .duplicateRecipients }
        #expect(finding?.severity == .notice)
        #expect(finding?.correction == .dedupeRecipients)
    }
}

@Suite("ComposeAdvice — reply-all")
struct ReplyAllGuardTests {
    private func address(_ n: Int) -> MailAddress { MailAddress(email: "p\(n)@x.com") }

    @Test("a wide reply-all is called out")
    func wideReplyAll() {
        let people = (1...7).map(address)
        let draft = ComposeDraftFacts(to: people, subject: "Re: Hi", bodyText: "Sure.",
                                      ownAddress: "me@x.com",
                                      replyAllParticipants: people)
        let finding = ComposeAdvice.findings(for: draft).first { $0.kind == .wideReplyAll }
        #expect(finding?.severity == .confirm)
        #expect(finding?.message.contains("7 people") == true)
    }

    @Test("a normal-sized reply-all is not called out")
    func narrowReplyAll() {
        let people = (1...4).map(address)
        let draft = ComposeDraftFacts(to: people, subject: "Re: Hi", bodyText: "Sure.",
                                      ownAddress: "me@x.com",
                                      replyAllParticipants: people)
        #expect(!ComposeAdvice.findings(for: draft).contains { $0.kind == .wideReplyAll })
    }

    @Test("a recipient who was not on the original thread is called out")
    func addedRecipient() {
        let original = [address(1), address(2)]
        let outsider = MailAddress(email: "outsider@y.com")
        let draft = ComposeDraftFacts(to: original, cc: [outsider], subject: "Re: Hi",
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
        let draft = ComposeDraftFacts(to: original, bcc: [MailAddress(email: "boss@y.com")],
                                      subject: "Re: Hi", bodyText: "Sure.",
                                      ownAddress: "me@x.com", replyAllParticipants: original)
        #expect(ComposeAdvice.findings(for: draft).contains { $0.kind == .replyAllAddsRecipients })
    }

    @Test("the account's own address is not treated as an outsider")
    func ownAddressIsNotAnOutsider() {
        let original = [address(1)]
        let draft = ComposeDraftFacts(to: original + [MailAddress(email: "me@x.com")],
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

@Suite("LookalikeAddress")
struct LookalikeAddressTests {
    private func candidate(_ email: String, frequency: Int) -> RecipientSuggestions.Candidate {
        RecipientSuggestions.Candidate(address: MailAddress(email: email, name: nil),
                                       frequency: frequency, mostRecent: Date())
    }

    @Test("a transposed domain is caught")
    func transposedDomain() {
        let matches = LookalikeAddress.matches(
            in: [MailAddress(email: "ahmed@gmial.com")],
            candidates: [candidate("ahmed@gmail.com", frequency: 12)])
        #expect(matches.count == 1)
        #expect(matches.first?.suggestion.email == "ahmed@gmail.com")
        #expect(matches.first?.distance == 1)
    }

    @Test("a transposed name is caught")
    func transposedName() {
        let matches = LookalikeAddress.matches(
            in: [MailAddress(email: "sahra.miller@example.com")],
            candidates: [candidate("sarah.miller@example.com", frequency: 6)])
        #expect(matches.first?.suggestion.email == "sarah.miller@example.com")
    }

    @Test("an address the account demonstrably uses is never flagged")
    func exactMatchNeverFlagged() {
        // Both are real contacts. Flagging one against the other would be
        // actively harmful.
        let matches = LookalikeAddress.matches(
            in: [MailAddress(email: "ahmed@gmail.com")],
            candidates: [candidate("ahmed@gmail.com", frequency: 1),
                         candidate("ahmed@gmai1.com", frequency: 30)])
        #expect(matches.isEmpty)
    }

    @Test("a one-off contact is not authoritative enough to correct against")
    func frequencyThreshold() {
        #expect(LookalikeAddress.matches(
            in: [MailAddress(email: "ahmed@gmial.com")],
            candidates: [candidate("ahmed@gmail.com", frequency: 1)]).isEmpty)
    }

    @Test("a genuinely different address is not flagged")
    func differentPerson() {
        #expect(LookalikeAddress.matches(
            in: [MailAddress(email: "someone.else@elsewhere.org")],
            candidates: [candidate("ahmed@gmail.com", frequency: 20)]).isEmpty)
    }

    @Test("short unrelated addresses are not flagged despite a small distance")
    func lengthGate() {
        // `a@x.com` -> `b@x.com` is one edit. A flat distance threshold flags
        // it; the length gate is what stops that.
        #expect(LookalikeAddress.matches(
            in: [MailAddress(email: "a@x.com")],
            candidates: [candidate("b@x.com", frequency: 20)]).isEmpty)
    }

    @Test("the nearest of several candidates is the one offered")
    func nearestWins() {
        let matches = LookalikeAddress.matches(
            in: [MailAddress(email: "ahmed@gmial.com")],
            candidates: [candidate("ahmed@gmail.com", frequency: 5),
                         candidate("ahmad@hotmail.com", frequency: 5)])
        #expect(matches.first?.suggestion.email == "ahmed@gmail.com")
    }

    @Test("Damerau-Levenshtein scores an adjacent transposition as one edit")
    func transpositionCostsOne() {
        // Plain Levenshtein scores this 2, which falls outside the threshold and
        // misses the single most common real typo.
        #expect(LookalikeAddress.editDistance("gmial", "gmail") == 1)
        #expect(LookalikeAddress.editDistance("abc", "abc") == 0)
        #expect(LookalikeAddress.editDistance("", "abc") == 3)
        #expect(LookalikeAddress.editDistance("kitten", "sitting") == 3)
    }

    @Test("the finding offers a replacement and changes nothing itself")
    func findingOffersCorrection() {
        let typed = MailAddress(email: "ahmed@gmial.com")
        let draft = ComposeDraftFacts(
            to: [typed], subject: "S", bodyText: "B",
            knownContacts: [candidate("ahmed@gmail.com", frequency: 9)])
        let finding = ComposeAdvice.findings(for: draft).first { $0.kind == .lookalikeAddress }
        #expect(finding?.severity == .confirm)
        #expect(finding?.correction
            == .replaceRecipient(from: typed, with: MailAddress(email: "ahmed@gmail.com")))
        #expect(draft.to == [typed])
    }
}

@Suite("BaseTextDirection")
struct BaseTextDirectionTests {
    @Test("an Arabic body is right-to-left")
    func arabic() {
        #expect(BaseTextDirection.detect("السلام عليكم، كيف حالك؟") == .rightToLeft)
    }

    @Test("an English body is left-to-right")
    func english() {
        #expect(BaseTextDirection.detect("Hello, how are you?") == .leftToRight)
    }

    @Test("empty and neutral-only text defaults to left-to-right")
    func neutral() {
        #expect(BaseTextDirection.detect("") == .leftToRight)
        #expect(BaseTextDirection.detect("123 -- 456 !!!") == .leftToRight)
    }

    @Test("an embedded Latin URL does not flip an Arabic message")
    func embeddedLatinRun() {
        #expect(BaseTextDirection.detect("تفضل الرابط هنا فضلا وشكرا جزيلا لك يا صديقي https://x.co")
            == .rightToLeft)
    }

    @Test("an Arabic reply to a long English thread is still right-to-left")
    func arabicReplyToEnglishThread() {
        // The rule that matters most for this user: the quoted original and its
        // attribution must not decide the direction of what they are writing.
        let reply = """
        شكرا جزيلا

        On Jan 1, 2020 at 9:00 AM, Beatrice Smith wrote:
        > Thank you very much for the update, I have reviewed the whole document
        > and everything looks correct to me. Let us proceed as planned tomorrow.
        """
        #expect(BaseTextDirection.detect(reply) == .rightToLeft)
    }

    @Test("only the authored portion is weighed, but a quote-only draft still resolves")
    func quoteOnlyFallback() {
        let quoteOnly = "\n\nOn Jan 1, 2020 at 9:00 AM, x wrote:\n> السلام عليكم ورحمة الله"
        // Nothing authored: falls back to the whole text rather than returning
        // a direction read from an empty string.
        #expect(BaseTextDirection.detect(quoteOnly) == .rightToLeft)
    }

    @Test("digits and punctuation are neutral, letters are not")
    func classification() {
        #expect(BaseTextDirection.isStrongRTL("م"))
        #expect(BaseTextDirection.isStrongRTL("ש"))
        #expect(!BaseTextDirection.isStrongRTL("a"))
        #expect(BaseTextDirection.isStrongLTR("a"))
        #expect(!BaseTextDirection.isStrongLTR("م"))
        #expect(!BaseTextDirection.isStrongLTR("5"))
        #expect(!BaseTextDirection.isStrongLTR("!"))
    }

    @Test("the HTML dir attribute value matches the direction")
    func htmlDir() {
        #expect(BaseTextDirection.rightToLeft.htmlDir == "rtl")
        #expect(BaseTextDirection.leftToRight.htmlDir == "ltr")
    }
}

@Suite("SchedulePresets")
struct SchedulePresetsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    private func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    @Test("every preset is strictly in the future")
    func allFuture() {
        for moment in ["2026-08-03 07:15", "2026-08-03 13:00", "2026-08-03 21:30",
                       "2026-08-08 23:59"] {
            let now = date(moment)
            for preset in SchedulePresets.presets(now: now, calendar: calendar) {
                #expect(preset.date > now, "\(preset.id) at \(moment) was not in the future")
            }
        }
    }

    @Test("tonight is 8pm today when 8pm has not passed")
    func tonightToday() {
        let now = date("2026-08-03 13:00")
        let tonight = SchedulePresets.presets(now: now, calendar: calendar)
            .first { $0.id == "tonight" }
        #expect(components(tonight!.date).hour == 20)
        #expect(components(tonight!.date).day == 3)
    }

    @Test("tonight is not offered at all once 8pm has passed")
    func tonightGoneLate() {
        // Rolling "Tonight" to tomorrow night would be a label that lies.
        let now = date("2026-08-03 21:30")
        #expect(!SchedulePresets.presets(now: now, calendar: calendar)
            .contains { $0.id == "tonight" })
    }

    @Test("tomorrow morning is 9am the following day, even at 3am")
    func tomorrowMorning() {
        for (moment, expectedDay) in [("2026-08-03 03:00", 4), ("2026-08-03 22:00", 4)] {
            let preset = SchedulePresets.presets(now: date(moment), calendar: calendar)
                .first { $0.id == "tomorrow" }
            #expect(components(preset!.date).hour == 9)
            #expect(components(preset!.date).day == expectedDay)
        }
    }

    @Test("Monday 9am lands on a Monday at 9")
    func mondayNine() {
        // 2026-08-03 is itself a Monday; from 13:00 the next Monday 9am is the
        // 10th, and from 07:15 it is today.
        let fromAfternoon = SchedulePresets.presets(now: date("2026-08-03 13:00"),
                                                    calendar: calendar)
            .first { $0.id == "monday" }!
        #expect(components(fromAfternoon.date).weekday == 2)
        #expect(components(fromAfternoon.date).hour == 9)
        #expect(components(fromAfternoon.date).day == 10)

        let fromEarly = SchedulePresets.presets(now: date("2026-08-03 07:15"),
                                                calendar: calendar)
            .first { $0.id == "monday" }!
        #expect(components(fromEarly.date).day == 3)
    }

    @Test("presets are uniquely identified so the UI can select one")
    func uniqueIDs() {
        let presets = SchedulePresets.presets(now: date("2026-08-03 13:00"), calendar: calendar)
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.count == 4)
    }
}
