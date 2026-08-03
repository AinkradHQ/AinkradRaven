import Testing
import Foundation
@testable import RavenFeature

/// `ComposeContext` is the threading/routing logic lifted out of the old
/// inline `ReplyPanel` when Reply/Reply-all/Forward moved into the single
/// compose overlay. These tests pin the invariants that panel enforced only
/// inline (and so untestably): a reply threads and routes to the thread's own
/// account, a forward threads onto nothing, and a new message is attributed to
/// whatever the composer resolved.
@Suite("Compose context")
struct ComposeContextTests {
    private let thread = ComposeThreadReference(threadID: "t-1", accountID: "acct-b",
                                               lastMessageRFC822ID: "<msg-9@example.com>")

    private func typed() -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "bea@example.com")], subject: "Re: hello",
                        bodyText: "body")
    }

    @Test("a new message is attributed to the composer's resolved account and threads onto nothing")
    func newMessage() {
        let stamped = ComposeContext.new.stamp(typed(), fallbackAccountID: "acct-a")
        #expect(stamped.accountID == "acct-a")
        #expect(stamped.threadID == nil)
        #expect(stamped.inReplyToMessageID == nil)
    }

    @Test("a reply threads onto the conversation and routes to the THREAD's account")
    func replyThreadsAndRoutes() {
        for mode in [ReplyComposer.Mode.reply, .replyAll] {
            let stamped = ComposeContext.reply(mode: mode, thread: thread)
                // Deliberately a different fallback: a reply must ignore it.
                .stamp(typed(), fallbackAccountID: "acct-a")
            #expect(stamped.accountID == "acct-b")
            #expect(stamped.threadID == "t-1")
            #expect(stamped.inReplyToMessageID == "<msg-9@example.com>")
        }
    }

    @Test("a forward routes to the thread's account but starts a NEW conversation")
    func forwardDoesNotThread() {
        let stamped = ComposeContext.reply(mode: .forward, thread: thread)
            .stamp(typed(), fallbackAccountID: "acct-a")
        #expect(stamped.accountID == "acct-b")
        #expect(stamped.threadID == nil)
        #expect(stamped.inReplyToMessageID == nil)
        #expect(ComposeContext.reply(mode: .forward, thread: thread)
            .threadsOntoExistingConversation == false)
    }

    @Test("stamping preserves everything the user actually typed or attached")
    func preservesTypedContent() {
        let attachment = OutgoingAttachment(filename: "a.txt", mimeType: "text/plain",
                                            data: Data("hi".utf8))
        let message = OutgoingMessage(to: [MailAddress(email: "bea@example.com")],
                                      cc: [MailAddress(email: "cec@example.com")],
                                      subject: "Re: hello", bodyText: "body",
                                      attachments: [attachment])
        let stamped = ComposeContext.reply(mode: .reply, thread: thread)
            .stamp(message, fallbackAccountID: nil)
        #expect(stamped.to.map(\.email) == ["bea@example.com"])
        #expect(stamped.cc.map(\.email) == ["cec@example.com"])
        #expect(stamped.subject == "Re: hello")
        #expect(stamped.bodyText == "body")
        #expect(stamped.attachments.map(\.filename) == ["a.txt"])
    }
}
