import Foundation

public enum MailError: Error, Equatable {
    case notAuthenticated(accountID: String)
    case unknownAccount(String)
    case unknownThread(String)
    case unknownDraft(String)
    case providerFailed(status: Int, message: String)
    case decodingFailed(String)
    /// A stored document exists but could not be decoded. Deliberately
    /// distinct from "absent": a read-modify-write path that cannot read what
    /// is already there must refuse to write, or it silently replaces real
    /// data with an empty collection.
    case documentCorrupt(key: String)
    case rateLimited(retryAfter: TimeInterval)
}
