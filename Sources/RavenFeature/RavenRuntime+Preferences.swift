import Foundation
import AinkradAppKit

/// The document-backed preferences and the one place saved rules get applied.
///
/// Grouped by a real shared property, not by leftover: every member here reads
/// or writes `host.documents` and holds no runtime state of its own, so each is
/// a pure accessor over persistence. That is also why they were the safest
/// members to move out of `RavenRuntime.swift` — none of them participates in
/// the sync, credential or send paths.
///
/// `updateSignature` and `log` used to sit under the "Rules" MARK, which they
/// had nothing to do with. They are here because a signature is a persisted
/// preference and `log` is the host accessor every one of these needs.
extension RavenRuntime {

    // MARK: Rules

    /// The user's saved filter rules — read fresh from `host.documents` on
    /// every access rather than cached, since `RavenSettingsView`'s rule
    /// editor writes the same document and must be reflected on the very
    /// next delta sync without this runtime needing to be told to reload.
    public var rules: RuleSet {
        get { RuleSet.load(documents: host.documents) }
        set { newValue.save(documents: host.documents) }
    }

    /// Runs the saved rules against exactly the thread ids a delta sync just
    /// discovered — see `SyncEngine.onNewThreads`'s documentation for why
    /// this must never be called with a wider set (e.g. everything in the
    /// store). Goes through `RuleEngine.apply`, which itself only ever calls
    /// `ThreadMutationApplier`/`outbox.enqueue` — never a provider directly.
    ///
    /// Internal rather than private only because `attach` — in
    /// `RavenRuntime+Sync.swift` — wires it as `SyncEngine.onNewThreads`.
    func applyRules(threadIDs: [String]) {
        let ruleSet = rules
        guard !ruleSet.rules.isEmpty else { return }
        RuleEngine.apply(ruleSet: ruleSet, threadIDs: threadIDs, store: store, outbox: outbox)
        model.reload()
    }

    // MARK: Signature

    /// Read-modify-write of the CURRENT account row.
    ///
    /// The Settings signature field used to write back a `MailAccount` value
    /// captured when the row was rendered, so every keystroke clobbered
    /// `syncCursor`, `lastSyncedAt`, `state` and `lastError` with whatever
    /// they were at render time — rolling the cursor back re-walks mail, and
    /// rolling it to `nil` forces a full backfill. Only the signature may
    /// change here.
    public func updateSignature(_ signature: String, accountID: String) {
        guard var account = store.accounts().first(where: { $0.id == accountID }),
              account.signature != signature else { return }
        account.signature = signature
        do {
            try store.saveAccount(account)
        } catch {
            host.log.error("Raven: could not save the signature: \(error)")
        }
    }

    // MARK: Undo-send hold window

    /// The undo-send hold window applied to every real send this runtime
    /// issues (compose, reply, and — see `RavenMCPOperations`'s `send_draft`
    /// documentation — Sage's `send_draft` too). Configurable from Accounts;
    /// `SendAttempt.defaultHoldWindow` (20s) until the user changes it.
    /// Persisted as a document since it is a preference, not a secret.
    public var holdWindow: TimeInterval {
        get {
            guard let data = host.documents.data(forKey: Self.holdWindowKey),
                  let seconds = try? JSONDecoder().decode(Double.self, from: data)
            else { return SendAttempt.defaultHoldWindow }
            return seconds
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                host.documents.setData(data, forKey: Self.holdWindowKey)
            }
        }
    }

    // MARK: Remote-image opt-in (persisted per sender)

    /// Whether `sender`'s remote images auto-load without the user pressing
    /// "Load images" again — see `RemoteImageAllowList`. Unknown senders
    /// default to blocked; this must never default to `true`.
    public func imagesAllowed(for sender: String) -> Bool {
        RemoteImageAllowList.isAllowed(sender, documents: host.documents)
    }

    /// Persists that `sender`'s images should auto-load from now on.
    public func allowImages(for sender: String) {
        RemoteImageAllowList.allow(sender, documents: host.documents)
    }

    /// Every sender previously granted "Load images", for the Privacy group in
    /// Settings to list. A read only — granting still happens exclusively from
    /// the message the user was looking at when they decided.
    public var allowedImageSenders: [String] {
        RemoteImageAllowList.allowedSenders(documents: host.documents)
    }

    /// Withdraws a previous grant, so that sender's images are blocked again.
    public func revokeImages(for sender: String) {
        RemoteImageAllowList.revoke(sender, documents: host.documents)
    }

    // MARK: Logging

    /// Routes a diagnostic line to the host's logger. Views must not `print()`
    /// — a shipped plugin's stdout goes nowhere the user or the host can see.
    public func log(_ message: String) {
        host.log.info(message)
    }
}
