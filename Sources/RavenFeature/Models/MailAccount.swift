import Foundation

public struct MailAccount: Codable, Equatable, Sendable, Identifiable {
    /// Which backend an account speaks to. Deliberately NOT a
    /// `String`-backed `RawRepresentable` enum any more, and that is the whole
    /// point of this type: `accounts` is a single document holding an ARRAY of
    /// accounts, so a `RawRepresentable` decode failure on one row fails the
    /// whole array and strands every other mailbox with it. An unrecognised
    /// kind therefore decodes to `.unsupported(_:)` — the row survives, its
    /// siblings load, and `ProviderFactory` refuses to build a provider for
    /// it with `MailError.unsupportedProvider`.
    ///
    /// The stored format is unchanged: this still encodes and decodes as the
    /// same bare JSON string it always did (`"gmail"`), and `.unsupported`
    /// carries the original string so re-saving the document round-trips a
    /// future build's value byte-for-byte rather than rewriting it.
    public enum ProviderKind: Codable, Hashable, Sendable {
        case gmail
        case imap
        case graph
        case appleMail
        /// A kind this build does not know — most likely written by a newer
        /// one. Never constructed from code; only from a decode.
        case unsupported(String)

        public init(identifier: String) {
            switch identifier {
            case "gmail": self = .gmail
            case "imap": self = .imap
            case "graph": self = .graph
            case "appleMail": self = .appleMail
            default: self = .unsupported(identifier)
            }
        }

        /// The stored string. `gmail` MUST stay `"gmail"` — existing
        /// `accounts` documents contain it.
        public var identifier: String {
            switch self {
            case .gmail: return "gmail"
            case .imap: return "imap"
            case .graph: return "graph"
            case .appleMail: return "appleMail"
            case .unsupported(let raw): return raw
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(identifier: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(identifier)
        }
    }
    /// Lenient for the SAME reason `ProviderKind` is, and it is worth stating
    /// separately because the reason is structural rather than about this
    /// field's meaning: `accounts` is one document holding an ARRAY, so ANY
    /// strict `RawRepresentable` field on this type is a single-row failure
    /// that strands every other mailbox. A newer build writing a state this one
    /// does not know (`"paused"`, say) must not sign the user out of everything.
    ///
    /// Unknown decodes to `.needsAuth`: it is the state that asks the user to
    /// look at the account rather than claiming a sync succeeded, and it is
    /// self-correcting — `SyncEngine` overwrites `state` on every pass, and the
    /// only consumer is a badge in `RavenSettingsAccounts`, so a wrong value
    /// survives at most one poll and can mislead nobody into losing data.
    public enum State: String, Codable, Sendable {
        case needsAuth, syncing, ready, failed

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .needsAuth
        }
    }

    public let id: String
    public let provider: ProviderKind
    public var address: String
    public var displayName: String
    /// Gmail `historyId`. Nil until the first backfill completes.
    public var syncCursor: String?
    public var state: State
    public var lastSyncedAt: Date?
    public var lastError: String?
    public var signature: String

    public init(id: String, provider: ProviderKind, address: String,
                displayName: String, syncCursor: String? = nil,
                state: State = .needsAuth, lastSyncedAt: Date? = nil,
                lastError: String? = nil, signature: String = "") {
        self.id = id; self.provider = provider; self.address = address
        self.displayName = displayName; self.syncCursor = syncCursor
        self.state = state; self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError; self.signature = signature
    }
}
