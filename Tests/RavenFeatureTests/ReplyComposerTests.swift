import Testing
import Foundation
@testable import RavenFeature

@Suite("Reply composer")
struct ReplyComposerTests {
    private func message(id: String, from: String, to: [String] = [], cc: [String] = [],
                         subject: String, date: Date, rfc822: String? = "rfc-\(UUID())") -> MailMessage {
        MailMessage(id: id, threadID: "t1", rfc822MessageID: rfc822,
                    from: MailAddress(email: from),
                    to: to.map { MailAddress(email: $0) }, cc: cc.map { MailAddress(email: $0) },
                    subject: subject, date: date, labelIDs: ["INBOX"])
    }

    @Test("reply addresses only the sender")
    func replyAddressesSender() {
        let msg = message(id: "m1", from: "sender@x.com", to: ["me@x.com"], cc: ["other@x.com"],
                          subject: "Hi", date: Date())
        let thread = MailThread(id: "t1", accountID: "a1", messages: [msg])
        let outgoing = ReplyComposer.compose(mode: .reply, thread: thread, lastMessage: msg,
                                             lastMessageBody: "hello", ownAddress: "me@x.com")
        #expect(outgoing.to.map(\.email) == ["sender@x.com"])
    }

    @Test("reply-all addresses the sender and every other participant, excluding the account's own address")
    func replyAllExcludesOwnAddress() {
        let msg = message(id: "m1", from: "sender@x.com",
                          to: ["me@x.com", "other@x.com"], cc: ["third@x.com"],
                          subject: "Hi", date: Date())
        let thread = MailThread(id: "t1", accountID: "a1", messages: [msg])
        let outgoing = ReplyComposer.compose(mode: .replyAll, thread: thread, lastMessage: msg,
                                             lastMessageBody: "hello", ownAddress: "me@x.com")
        let emails = Set(outgoing.to.map(\.email))
        #expect(emails == ["sender@x.com", "other@x.com", "third@x.com"])
        #expect(!emails.contains("me@x.com"))
    }

    @Test("reply-all excludes the account's own address case-insensitively")
    func replyAllExcludesOwnAddressCaseInsensitive() {
        let msg = message(id: "m1", from: "sender@x.com", to: ["ME@X.com"],
                          subject: "Hi", date: Date())
        let thread = MailThread(id: "t1", accountID: "a1", messages: [msg])
        let outgoing = ReplyComposer.compose(mode: .replyAll, thread: thread, lastMessage: msg,
                                             lastMessageBody: "hello", ownAddress: "me@x.com")
        #expect(!outgoing.to.map { $0.email.lowercased() }.contains("me@x.com"))
    }

    @Test("forward addresses nobody and prefills quoted original")
    func forwardAddressesNobody() {
        let msg = message(id: "m1", from: "sender@x.com", to: ["me@x.com"],
                          subject: "Hi", date: Date())
        let thread = MailThread(id: "t1", accountID: "a1", messages: [msg])
        let outgoing = ReplyComposer.compose(mode: .forward, thread: thread, lastMessage: msg,
                                             lastMessageBody: "hello there", ownAddress: "me@x.com")
        #expect(outgoing.to.isEmpty)
        #expect(outgoing.bodyText.contains("> hello there"))
        #expect(outgoing.inReplyToMessageID == nil)
        #expect(outgoing.threadID == nil)
    }

    @Test("subject gets a single Re: prefix and never doubles up")
    func subjectDoesNotDoublePrefix() {
        #expect(ReplyComposer.prefixedSubject("Hello", isForward: false) == "Re: Hello")
        #expect(ReplyComposer.prefixedSubject("Re: Hello", isForward: false) == "Re: Hello")
        #expect(ReplyComposer.prefixedSubject("Re: Re: Hello", isForward: false) == "Re: Hello")
        #expect(ReplyComposer.prefixedSubject("RE: Hello", isForward: false) == "Re: Hello")
    }

    @Test("forward gets a single Fwd: prefix and never doubles up")
    func subjectForwardDoesNotDoublePrefix() {
        #expect(ReplyComposer.prefixedSubject("Hello", isForward: true) == "Fwd: Hello")
        #expect(ReplyComposer.prefixedSubject("Fwd: Hello", isForward: true) == "Fwd: Hello")
        #expect(ReplyComposer.prefixedSubject("Fwd: Fwd: Hello", isForward: true) == "Fwd: Hello")
    }

    @Test("subject prefixing handles a non-ASCII (Arabic) subject without mangling it")
    func subjectHandlesArabic() {
        let arabic = "مرحبا بالعالم"
        #expect(ReplyComposer.prefixedSubject(arabic, isForward: false) == "Re: \(arabic)")
        let already = "Re: \(arabic)"
        #expect(ReplyComposer.prefixedSubject(already, isForward: false) == "Re: \(arabic)")
    }

    @Test("inReplyToMessageID and threadID are both set on a reply's OutgoingMessage")
    func replySetsThreadingFields() {
        let msg = message(id: "m1", from: "sender@x.com", subject: "Hi", date: Date(),
                          rfc822: "<abc123@mail.gmail.com>")
        let thread = MailThread(id: "thread-xyz", accountID: "a1", messages: [msg])
        let outgoing = ReplyComposer.compose(mode: .reply, thread: thread, lastMessage: msg,
                                             lastMessageBody: "hello", ownAddress: nil)
        #expect(outgoing.inReplyToMessageID == "<abc123@mail.gmail.com>")
        #expect(outgoing.threadID == "thread-xyz")
    }

    @Test("the quoted body round-trips through QuoteTrimmer.split")
    func quotedBodyRoundTripsThroughQuoteTrimmer() {
        let msg = message(id: "m1", from: "sender@x.com", subject: "Hi", date: Date())
        let thread = MailThread(id: "t1", accountID: "a1", messages: [msg])
        let outgoing = ReplyComposer.compose(mode: .reply, thread: thread, lastMessage: msg,
                                             lastMessageBody: "Original message body.",
                                             ownAddress: nil)
        let split = QuoteTrimmer.split(outgoing.bodyText)
        #expect(split.visible.isEmpty)
        #expect(split.quoted != nil)
        #expect(split.quoted?.contains("> Original message body.") == true)
        #expect(split.quoted?.contains("wrote:") == true)
    }
}
