import Testing
import Foundation
@testable import RavenFeature

@Suite("RecipientSuggestions")
struct RecipientSuggestionsTests {
    private func summary(id: String, participants: [MailAddress], date: Date) -> ThreadSummary {
        ThreadSummary(id: id, accountID: "a1", subject: "s", participants: participants,
                     lastMessageDate: date, messageCount: 1, unreadCount: 0, isStarred: false,
                     labelIDs: [], snippet: "")
    }

    @Test("ranks by frequency first, not alphabetically")
    func ranksByFrequency() {
        let alice = MailAddress(email: "alice@x.com", name: "Alice")
        let zeke = MailAddress(email: "zeke@x.com", name: "Zeke")
        let now = Date()
        let summaries = [
            summary(id: "1", participants: [zeke], date: now),
            summary(id: "2", participants: [zeke], date: now),
            summary(id: "3", participants: [alice], date: now),
        ]
        let candidates = RecipientSuggestions.candidates(from: summaries)
        let ranked = RecipientSuggestions.match("", in: candidates)
        // Zeke has frequency 2, Alice frequency 1 — alphabetical order would
        // put Alice first, frequency ranking must not.
        #expect(ranked.first?.address.email == "zeke@x.com")
    }

    @Test("ties on frequency break by recency — this morning outranks two months ago")
    func ranksByRecencyOnTie() {
        let bea = MailAddress(email: "bea@x.com", name: "Bea Smith")
        let cal = MailAddress(email: "cal@x.com", name: "Cal Jones")
        let thisMorning = Date()
        let twoMonthsAgo = Calendar(identifier: .gregorian).date(byAdding: .month, value: -2, to: thisMorning)!
        let summaries = [
            summary(id: "1", participants: [cal], date: twoMonthsAgo),
            summary(id: "2", participants: [bea], date: thisMorning),
        ]
        let candidates = RecipientSuggestions.candidates(from: summaries)
        let ranked = RecipientSuggestions.match("", in: candidates)
        #expect(ranked.first?.address.email == "bea@x.com")
    }

    @Test("matches on display name as well as address")
    func matchesDisplayName() {
        let bea = MailAddress(email: "bea@x.com", name: "Bea Smith")
        let summaries = [summary(id: "1", participants: [bea], date: Date())]
        let candidates = RecipientSuggestions.candidates(from: summaries)
        let matched = RecipientSuggestions.match("Bea", in: candidates)
        #expect(matched.map(\.address.email) == ["bea@x.com"])
    }

    @Test("matches on address when the query is not a name")
    func matchesAddress() {
        let bea = MailAddress(email: "bea@x.com", name: "Bea Smith")
        let summaries = [summary(id: "1", participants: [bea], date: Date())]
        let candidates = RecipientSuggestions.candidates(from: summaries)
        let matched = RecipientSuggestions.match("bea@x", in: candidates)
        #expect(matched.map(\.address.email) == ["bea@x.com"])
    }

    @Test("a query matching nobody returns nothing")
    func noMatch() {
        let bea = MailAddress(email: "bea@x.com", name: "Bea Smith")
        let summaries = [summary(id: "1", participants: [bea], date: Date())]
        let candidates = RecipientSuggestions.candidates(from: summaries)
        #expect(RecipientSuggestions.match("nobody", in: candidates).isEmpty)
    }
}
