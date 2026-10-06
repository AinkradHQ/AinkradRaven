@testable import RavenFeature

/// Shared builders for the outbox suites (`OutboxTests`,
/// `OutboxHoldAndWakeTests`): a suite conforms and calls them as before.
@MainActor protocol OutboxTestSupport {}

extension OutboxTestSupport {
    func makeOutbox(
        _ provider: FakeMailProvider, maxAttempts: Int = 3,
        accountID: String? = nil
    )
        -> (Outbox, InMemoryDocumentStore)
    {
        let documents = InMemoryDocumentStore()
        return (
            Outbox(
                documents: documents, provider: provider, maxAttempts: maxAttempts,
                accountID: accountID), documents
        )
    }

    func aMessage() -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "b@x.com")], subject: "Hi", bodyText: "There")
    }
}
