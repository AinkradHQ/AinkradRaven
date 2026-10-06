import Foundation
import Testing

@testable import RavenFeature

@Suite("LookalikeAddress")
struct LookalikeAddressTests {
    private func candidate(_ email: String, frequency: Int) -> RecipientSuggestions.Candidate {
        RecipientSuggestions.Candidate(
            address: MailAddress(email: email, name: nil),
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
            candidates: [
                candidate("ahmed@gmail.com", frequency: 1),
                candidate("ahmed@gmai1.com", frequency: 30),
            ])
        #expect(matches.isEmpty)
    }

    @Test("a one-off contact is not authoritative enough to correct against")
    func frequencyThreshold() {
        #expect(
            LookalikeAddress.matches(
                in: [MailAddress(email: "ahmed@gmial.com")],
                candidates: [candidate("ahmed@gmail.com", frequency: 1)]
            ).isEmpty)
    }

    @Test("a genuinely different address is not flagged")
    func differentPerson() {
        #expect(
            LookalikeAddress.matches(
                in: [MailAddress(email: "someone.else@elsewhere.org")],
                candidates: [candidate("ahmed@gmail.com", frequency: 20)]
            ).isEmpty)
    }

    @Test("short unrelated addresses are not flagged despite a small distance")
    func lengthGate() {
        // `a@x.com` -> `b@x.com` is one edit. A flat distance threshold flags
        // it; the length gate is what stops that.
        #expect(
            LookalikeAddress.matches(
                in: [MailAddress(email: "a@x.com")],
                candidates: [candidate("b@x.com", frequency: 20)]
            ).isEmpty)
    }

    @Test("the nearest of several candidates is the one offered")
    func nearestWins() {
        let matches = LookalikeAddress.matches(
            in: [MailAddress(email: "ahmed@gmial.com")],
            candidates: [
                candidate("ahmed@gmail.com", frequency: 5),
                candidate("ahmad@hotmail.com", frequency: 5),
            ])
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
        #expect(
            finding?.correction
                == .replaceRecipient(from: typed, with: MailAddress(email: "ahmed@gmail.com")))
        #expect(draft.to == [typed])
    }
}
