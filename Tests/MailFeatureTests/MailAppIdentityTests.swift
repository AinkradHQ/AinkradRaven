import Testing
@testable import MailFeature

@Suite("MailApp identity")
struct MailAppIdentityTests {
    @Test("app id matches the Info.plist AinkradAppID")
    @MainActor func identity() {
        #expect(MailApp.id == "mail")
        #expect(MailApp.displayName == "Mail")
    }
}
