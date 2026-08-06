import Testing
import Foundation
@testable import RavenFeature

@Suite("Thread search")
struct ThreadSearchTests {
    private func summary(_ id: String, subject: String, from: String,
                         labels: [String] = ["INBOX"], unread: Int = 0) -> ThreadSummary {
        ThreadSummary(id: id, accountID: "a1", subject: subject,
                      participants: [MailAddress(email: from)],
                      lastMessageDate: Date(), messageCount: 1, unreadCount: unread,
                      isStarred: false, labelIDs: labels, snippet: "")
    }

    private var corpus: [ThreadSummary] {
        [summary("t1", subject: "Invoice March", from: "billing@acme.com"),
         summary("t2", subject: "Lunch?", from: "bea@x.com", unread: 1),
         summary("t3", subject: "Invoice April", from: "billing@acme.com", labels: ["ARCHIVE"])]
    }

    @Test("a bare term matches the subject, case-insensitively")
    func matchesSubject() {
        #expect(Set(ThreadSearch.match(corpus, query: "invoice").map(\.id)) == ["t1", "t3"])
    }

    @Test("from: narrows by participant address")
    func matchesFrom() {
        #expect(Set(ThreadSearch.match(corpus, query: "from:bea").map(\.id)) == ["t2"])
    }

    @Test("is:unread narrows to unread threads")
    func matchesUnread() {
        #expect(ThreadSearch.match(corpus, query: "is:unread").map(\.id) == ["t2"])
    }

    @Test("label: narrows by label id")
    func matchesLabel() {
        #expect(ThreadSearch.match(corpus, query: "label:ARCHIVE").map(\.id) == ["t3"])
    }

    @Test("operators combine as AND")
    func combinesOperators() {
        let hits = ThreadSearch.match(corpus, query: "invoice label:INBOX")
        #expect(hits.map(\.id) == ["t1"])
    }

    @Test("an empty query returns everything rather than nothing")
    func emptyQuery() {
        #expect(ThreadSearch.match(corpus, query: "   ").count == 3)
    }

    @Test("an operator with no value is ignored rather than matching everything or nothing")
    func emptyOperatorValueIsIgnored() {
        // "from:" alone contributes no constraint; all three threads should still match.
        #expect(ThreadSearch.match(corpus, query: "from:").count == 3)
        #expect(ThreadSearch.match(corpus, query: "label:").count == 3)
        // Combined with a real term, the empty operator still shouldn't narrow anything.
        #expect(Set(ThreadSearch.match(corpus, query: "invoice from:").map(\.id)) == ["t1", "t3"])
    }

    @Test("label: is case-insensitive so lowercase user input matches uppercase system labels")
    func labelMatchIsCaseInsensitive() {
        #expect(ThreadSearch.match(corpus, query: "label:archive").map(\.id) == ["t3"])
        #expect(Set(ThreadSearch.match(corpus, query: "label:inbox").map(\.id)) == ["t1", "t2"])
    }
}
