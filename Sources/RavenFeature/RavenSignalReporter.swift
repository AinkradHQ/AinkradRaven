import Foundation
import AinkradAppKit

/// Raven's notification vocabulary, in one place so the kinds stay consistent
/// and every emission decision is visible together.
@MainActor
struct RavenSignalReporter {
    let signals: PluginSignalEmitter

    /// New mail arrived during a sync pass.
    ///
    /// One event per pass carrying a count, not one per thread: a delta that
    /// brings in forty threads is one thing that happened, and forty rows would
    /// bury everything else in the feed. The dedupe key is the account, so a
    /// busy inbox coalesces into a single row the host counts up.
    func mailArrived(count: Int, accountLabel: String) {
        guard count > 0 else { return }
        signals.emit(
            kind: "mail.arrived",
            severity: .info,
            title: count == 1 ? "New message" : "\(count) new messages",
            body: accountLabel,
            // `.normal`, not `.urgent`: mail is routine. A user who wants it
            // quieter can mute Raven; one who wants it louder can raise it.
            importance: .normal,
            dedupeKey: "raven.mail:\(accountLabel)")
    }

    /// Authentication failed — the account needs the user, and no amount of
    /// retrying will fix it.
    ///
    /// The only Raven event that is `.urgent`: mail silently stops arriving
    /// until it is dealt with, and the failure is invisible unless the user
    /// happens to open the Accounts surface.
    func authenticationFailed(accountLabel: String) {
        signals.emit(
            kind: "account.auth-failed",
            severity: .failure,
            title: "\(accountLabel) needs signing in again",
            body: "Mail will not sync until this account is re-authenticated.",
            importance: .urgent,
            dedupeKey: "raven.auth:\(accountLabel)")
    }

    /// A sync pass failed for a reason that is not authentication.
    ///
    /// `.warning`, not `.failure`: these are usually transient (a rate limit, a
    /// network blip) and the next scheduled pass retries against the same
    /// cursor. Reporting every one as a failure would train the user to ignore
    /// the ones that matter.
    func syncFailed(accountLabel: String, reason: String) {
        signals.emit(
            kind: "sync.failed",
            severity: .warning,
            title: "Could not sync \(accountLabel)",
            body: reason,
            importance: .normal,
            dedupeKey: "raven.sync:\(accountLabel)")
    }
}
