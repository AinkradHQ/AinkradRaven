import Testing
@testable import RavenFeature

@Suite("RavenApp identity")
struct RavenAppIdentityTests {
    @Test("app id matches the Info.plist AinkradAppID")
    @MainActor func identity() {
        #expect(RavenApp.id == "raven")
        #expect(RavenApp.displayName == "Raven")
    }
}
