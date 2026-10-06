import Foundation
import Testing

@testable import RavenFeature

@Suite("RecipientDedupe")
struct RecipientDedupeTests {
    @Test("the same address in To and Cc is kept once, in To")
    func acrossFields() {
        let bea = MailAddress(email: "bea@x.com")
        let result = RecipientDedupe.apply(
            to: [bea], cc: [bea], bcc: [],
            ownAddress: "me@x.com")
        #expect(result.to == [bea])
        #expect(result.cc.isEmpty)
        #expect(result.duplicates == [bea])
    }

    @Test("To wins over Cc which wins over Bcc — never a silent downgrade to blind")
    func precedence() {
        let bea = MailAddress(email: "bea@x.com")
        let cal = MailAddress(email: "cal@x.com")
        let result = RecipientDedupe.apply(
            to: [], cc: [bea], bcc: [bea, cal],
            ownAddress: nil)
        #expect(result.cc == [bea])
        #expect(result.bcc == [cal])
    }

    @Test("case differences are the same person")
    func caseInsensitive() {
        let result = RecipientDedupe.apply(
            to: [MailAddress(email: "Bea@X.com")],
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
        let a = MailAddress(email: "a@x.com")
        let b = MailAddress(email: "b@x.com")
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
        let derived = ReplyComposer.recipients(
            mode: .replyAll, lastMessage: last,
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
