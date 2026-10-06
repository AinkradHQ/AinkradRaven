import Foundation

@testable import RavenFeature

/// Shared builders for the `DocumentMailStore` suites (`DocumentMailStoreTests`,
/// `DocumentMailStoreIntegrityTests`): a suite conforms and calls them as before.
@MainActor protocol DocumentMailStoreFixtures {}

extension DocumentMailStoreFixtures {
    func makeStore() -> (DocumentMailStore, InMemoryDocumentStore) {
        let documents = InMemoryDocumentStore()
        return (DocumentMailStore(documents: documents), documents)
    }

    /// The store's own date strategy, so a hand-planted document decodes.
    var coder: (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// Every month shard the account has ever written, read straight out of the
    /// month registry — the only enumeration a key→Data store allows.
    func registeredMonths(
        _ documents: InMemoryDocumentStore,
        accountID: String
    ) throws -> [String] {
        guard let data = documents.storage[DocumentKeys.indexMonths(accountID: accountID)]
        else { return [] }
        return try coder.1.decode([String].self, from: data)
    }

    func message(
        _ id: String, thread: String, date: Date,
        read: Bool = false
    ) -> MailMessage {
        MailMessage(
            id: id, threadID: thread, from: MailAddress(email: "b@x.com"),
            subject: "Subject", date: date, isRead: read,
            labelIDs: ["INBOX"], snippet: "snip")
    }
}
