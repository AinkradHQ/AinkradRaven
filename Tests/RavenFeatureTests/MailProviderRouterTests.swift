import Testing
import Foundation
@testable import RavenFeature

/// Router-level enforcement of `MailProviderCapabilities` — the chokepoint
/// every send/label-mutation routing path must go through so a read-only
/// backend (Apple Mail import) is refused before it ever reaches a provider.
@Suite("MailProviderRouter capability enforcement")
@MainActor struct MailProviderRouterTests {
    @Test("writableProvider refuses a read-only account's provider")
    func refusesReadOnlyAccount() {
        let router = MailProviderRouter()
        let readOnly = FakeMailProvider(accountID: "ro1")
        readOnly.capabilities = .readOnly
        router.attach(readOnly, accountID: "ro1")

        #expect(throws: MailError.readOnlyAccount("ro1")) {
            _ = try router.writableProvider(for: "ro1")
        }
    }

    @Test("writableProvider returns a read-write account's provider")
    func returnsReadWriteAccount() throws {
        let router = MailProviderRouter()
        let readWrite = FakeMailProvider(accountID: "rw1")
        readWrite.capabilities = .readWrite
        router.attach(readWrite, accountID: "rw1")

        let resolved = try router.writableProvider(for: "rw1")
        #expect(resolved.accountID == "rw1")
    }

    @Test("writableProvider refuses an account with no provider attached")
    func refusesUnknownAccount() {
        let router = MailProviderRouter()
        #expect(throws: MailError.unknownAccount("nope")) {
            _ = try router.writableProvider(for: "nope")
        }
    }

    @Test("Outbox.drain never calls send on a read-only provider, and dead-letters instead")
    func outboxRefusesReadOnlyProviderSend() async throws {
        let readOnly = FakeMailProvider(accountID: "ro1")
        readOnly.capabilities = .readOnly
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: readOnly, maxAttempts: 1)

        try outbox.enqueue(.send(OutgoingMessage(to: [MailAddress(email: "a@b.com")],
                                                  subject: "s", bodyText: "b")))
        await outbox.drain()

        #expect(readOnly.sentMessages.isEmpty)
        #expect(outbox.deadLettered().count == 1)
        #expect(outbox.deadLettered().first?.lastError?.contains("readOnlyAccount") == true)
    }
}
