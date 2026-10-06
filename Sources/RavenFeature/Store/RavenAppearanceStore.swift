import AinkradAppKit
import Foundation
import Observation

/// Owns the persisted `RavenAppearance`.
///
/// A separate `@Observable` object rather than a computed property on
/// `RavenRuntime` for two reasons. It has to be observable: the control lives
/// in the host's settings overlay, which is a different view tree from the
/// Raven pane, so the pane only repaints as the slider moves if the write is
/// something SwiftUI tracks — `RavenRuntime.holdWindow`'s pattern (a computed
/// property straight over `host.documents`) is invisible to observation and
/// would leave the pane stale until it happened to re-render for some other
/// reason. And it keeps `RavenRuntime`, already the largest file here, from
/// growing another stored property and its persistence.
@MainActor @Observable public final class RavenAppearanceStore {
    private let documents: PluginDocumentStore
    private static let key = DocumentKeys.appearance

    /// Write-through: the in-memory value is what views observe, the document
    /// is what survives a relaunch. Persisting on `didSet` rather than making
    /// the getter read the document keeps the read off the disk on every
    /// render pass of every message card.
    public var appearance: RavenAppearance {
        didSet {
            guard appearance != oldValue else { return }
            if let data = try? JSONEncoder().encode(appearance) {
                documents.setData(data, forKey: Self.key)
            }
        }
    }

    public init(documents: PluginDocumentStore) {
        self.documents = documents
        if let data = documents.data(forKey: Self.key),
            let stored = try? JSONDecoder().decode(RavenAppearance.self, from: data)
        {
            self.appearance = stored
        } else {
            // No stored value — the out-of-the-box look, not the extreme of
            // the range.
            self.appearance = .default
        }
    }
}
