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
    /// The message's attachments push it over Gmail's send-size limit — see
    /// `AttachmentSizeGuard`. Thrown before anything is queued, so a caller
    /// catching this knows nothing was enqueued and nothing needs cleanup.
    case attachmentsTooLarge(message: String)
    /// A mutation (`send`/`applyLabels`) was routed to an account whose
    /// provider declares `.readOnly` — e.g. an imported Apple Mail mailbox,
    /// which has no transport of its own to send or mutate through. Thrown
    /// at the routing layer (`MailProviderRouter.writableProvider`) rather
    /// than left to the provider itself, so every caller gets the same
    /// refusal regardless of which read-only backend is attached.
    case readOnlyAccount(String)
    /// The stored account names a provider kind this build cannot construct —
    /// either `MailAccount.ProviderKind.unsupported` (a kind written by a
    /// newer build) or a kind whose backend is not wired up yet. Thrown by
    /// `ProviderFactory`, never by a provider: the account row itself stays
    /// readable and every OTHER account stays attached, which is the whole
    /// reason the kind decodes leniently in the first place.
    case unsupportedProvider(kind: String, accountID: String)
    /// The provider refused this operation **permanently** — an SMTP `5yz`, a
    /// rejected credential, a server that will not offer TLS. Distinct from
    /// `.providerFailed`, which `Outbox.drain` retries with backoff: this one is
    /// dead-lettered on the first failure, because five more attempts buy five
    /// more identical refusals and delay the human who has to fix the cause.
    /// `message` is server-authored text or a fixed phrase — never a credential.
    case sendRefused(status: Int, message: String)
    /// The message data was fully transmitted and the server's verdict never
    /// arrived, so whether it was sent is **unknown**. `Outbox.drain` holds an
    /// entry that fails this way for review (`OutboxSendOutcome.needsReview`)
    /// rather than retrying it: retrying might deliver the same email twice,
    /// which is the one failure this app's send path is built to never risk. See
    /// `SMTPSession.finishData`, the only place this originates.
    case sendOutcomeUnknown(message: String)
}
