import Foundation

/// What a failed outbox operation should become. Extracted from `Outbox.drain`'s
/// `catch` so the decision is a pure function that can be asserted directly —
/// and so `Outbox.swift`, the one file already grandfathered past this repo's
/// line limit, does not grow to carry it.
enum OutboxFailure {
    enum Disposition: Equatable, Sendable {
        /// Count the attempt and try again later, dead-lettering once the
        /// attempts run out. The default, and what every error that predates the
        /// SMTP path still gets.
        case retry
        /// Never retry: the provider has refused permanently (an SMTP `5yz`, a
        /// rejected credential). Surfaced to the user on the first failure.
        case deadLetter
        /// Never retry, and do not claim it failed either: the operation may
        /// already have taken effect and there is no way to tell. Held for a
        /// human, the same fate as an entry found in flight after a crash.
        case review
    }

    /// The one mapping from a thrown error to a fate.
    ///
    /// Only two errors are exceptions to "retry", and both are exceptions for the
    /// same reason `Outbox` refuses to infer success from absence: a send is
    /// irreversible, so an automatic retry has to be provably safe.
    static func disposition(for error: any Error) -> Disposition {
        switch error {
        case MailError.sendOutcomeUnknown: return .review
        case MailError.sendRefused: return .deadLetter
        default: return .retry
        }
    }

    /// Applies `error`'s disposition to `entry`. Records the error text on the
    /// entry in every case — a held or dead-lettered entry with no explanation is
    /// unresolvable by the human it is being handed to.
    static func apply(_ error: any Error, to entry: inout OutboxEntry, maxAttempts: Int) {
        entry.inFlightAt = nil
        entry.lastError = String(describing: error)
        switch disposition(for: error) {
        case .review:
            entry.needsReview = true
        case .deadLetter:
            entry.isDeadLettered = true
        case .retry:
            entry.attempts += 1
            if entry.attempts >= maxAttempts { entry.isDeadLettered = true }
        }
    }
}
