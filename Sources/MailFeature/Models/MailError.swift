import Foundation

public enum MailError: Error, Equatable {
    case notAuthenticated(accountID: String)
    case unknownAccount(String)
    case unknownThread(String)
    case unknownDraft(String)
    case providerFailed(status: Int, message: String)
    case decodingFailed(String)
    case rateLimited(retryAfter: TimeInterval)
}
