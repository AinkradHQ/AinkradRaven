import Testing
@testable import MailFeature

@Suite("Quote trimmer")
struct QuoteTrimmerTests {
    @Test("an On-wrote attribution starts the quoted trailer")
    func splitsOnAttribution() {
        let body = """
        Sounds good.

        On Mon, 2 Aug 2026 at 10:00, Bea <b@x.com> wrote:
        > the original
        """
        let split = QuoteTrimmer.split(body)
        #expect(split.visible.trimmingCharacters(in: .whitespacesAndNewlines) == "Sounds good.")
        #expect(split.quoted?.contains("the original") == true)
    }

    @Test("a leading > block is quoted from the first line")
    func splitsOnMarker() {
        let split = QuoteTrimmer.split("> only a quote")
        #expect(split.visible.isEmpty)
        #expect(split.quoted?.contains("only a quote") == true)
    }

    @Test("a body with no quote returns no trailer")
    func noQuote() {
        let split = QuoteTrimmer.split("Just a note.")
        #expect(split.visible == "Just a note.")
        #expect(split.quoted == nil)
    }
}
