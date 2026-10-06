import Foundation

@testable import RavenFeature

/// Shared builders for the multi-account suites (`MultiAccountTests`,
/// `MultiAccountMCPTests`): a suite conforms and calls them as before.
@MainActor protocol MultiAccountFixtures {}

extension MultiAccountFixtures {
    func thread(
        _ id: String, account: String, subject: String, date: Date,
        unread: Bool = false
    ) -> MailThread {
        MailThread(
            id: id, accountID: account,
            messages: [
                MailMessage(
                    id: "m-\(id)", threadID: id, from: MailAddress(email: "s@x.com"),
                    subject: subject, date: date, isRead: !unread,
                    labelIDs: unread ? ["INBOX", "UNREAD"] : ["INBOX"], snippet: "s")
            ])
    }

    func store(accounts: [String]) throws -> DocumentMailStore {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        for id in accounts {
            try store.saveAccount(
                MailAccount(
                    id: id, provider: .gmail, address: "\(id)@x.com",
                    displayName: id, state: .ready))
        }
        return store
    }
}
