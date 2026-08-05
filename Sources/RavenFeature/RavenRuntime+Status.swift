import Foundation
import AinkradAppKit

/// The READ side of `RavenRuntime`'s per-account status mirrors: the four
/// per-account accessors and the two app-wide roll-ups computed from them.
///
/// Split out of `RavenRuntime.swift` when Task 14's IDLE state pushed that file
/// past the repo's 500-line limit, and split along the one seam that is safe here:
/// everything in this file only ever READS `syncStates`/`syncErrors`/
/// `truncatedBackfills`/`pushStates`. The matching WRITE side — `setSyncState`,
/// `setSyncError`, `setPushState`, `setTruncated`, `refreshAggregateSyncError` —
/// deliberately did NOT move, and cannot: `private(set)` is file-scoped in Swift,
/// so an extension in another file cannot assign to those properties at all.
/// Widening them to `internal(set)` to make a move possible would hand every view
/// and every MCP operation in `RavenFeature` blanket write access to the sync
/// state, which is exactly the second source of truth that section's own
/// documentation exists to prevent. So the split leaves the narrow write surface
/// where it is and moves only what any file could already have computed.
extension RavenRuntime {

    // MARK: Per-account status

    public func syncState(for accountID: String) -> SyncState {
        syncStates[accountID] ?? .idle
    }

    public func lastSyncError(for accountID: String) -> String? {
        syncErrors[accountID]
    }

    /// A sentence for the Accounts surface about this account's near-push
    /// connection, or `nil` when there is nothing worth saying — a healthy IDLE
    /// connection, or an account kind that never had one. See `RavenPushState`.
    public func pushStatus(for accountID: String) -> String? {
        pushStates[accountID]?.message
    }

    public func lastBackfillTruncated(for accountID: String) -> Bool {
        truncatedBackfills.contains(accountID)
    }

    // MARK: App-wide roll-ups

    /// App-wide roll-up of `syncStates`, for the places that legitimately show
    /// one status for everything (the Settings panel's change trigger). A
    /// failure anywhere wins, because "some account is broken" must not be
    /// hidden by another account being idle; otherwise an in-progress backfill
    /// wins, with the thread counts summed.
    public var syncState: SyncState {
        if let failure = syncStates.values.compactMap({ state -> String? in
            if case .failed(let message) = state { return message }
            return nil
        }).sorted().first {
            return .failed(failure)
        }
        let backfilling = syncStates.values.compactMap { state -> Int? in
            if case .backfilling(let count) = state { return count }
            return nil
        }
        if !backfilling.isEmpty { return .backfilling(threadsSynced: backfilling.reduce(0, +)) }
        if syncStates.values.contains(.delta) { return .delta }
        return .idle
    }

    /// Surfaced separately from `syncState` on purpose — see `SyncEngine`'s
    /// own documentation of `lastBackfillTruncated`: it is a plain flag, not
    /// a `SyncState` case, so a view that renders only `syncState` would
    /// silently miss it. True when it happened on ANY account; per-account
    /// truth is `lastBackfillTruncated(for:)`.
    public var lastBackfillTruncated: Bool { !truncatedBackfills.isEmpty }
}
