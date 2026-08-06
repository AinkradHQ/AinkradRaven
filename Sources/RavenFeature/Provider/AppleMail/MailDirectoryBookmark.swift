import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Wraps the security-scoped bookmark dance around a user-chosen directory
/// (Mail.app's on-disk store) so `AppleMailProvider`/`AppleMailImporter` can
/// re-open it across launches without re-prompting, and can start/stop the
/// scoped access around each file operation as `NSOpenPanel`'s own contract
/// requires.
///
/// The directory picker itself (`pickDirectory`) is UI-only and not
/// meaningfully testable headlessly — it opens a real `NSOpenPanel`. Every
/// other operation here (create/resolve/start/stop) is plain `URL` API and is
/// exercised directly in `MailDirectoryBookmarkTests` against a temp
/// directory.
public struct MailDirectoryBookmark: Sendable {
    public let data: Data

    public init(data: Data) { self.data = data }

    /// Presents the picker and returns a bookmark for the folder the user
    /// chose, or `nil` if they cancelled. UI-only — never called from a test.
    #if canImport(AppKit)
    @MainActor
    public static func pickDirectory(prompt: String = "Choose your Mail folder") -> MailDirectoryBookmark? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? create(for: url)
    }
    #endif

    /// Encodes `url` as a security-scoped bookmark. Production callers always
    /// get `.withSecurityScope`; tests running outside an App Sandbox — where
    /// that option is documented to be unusable — fall back to plain
    /// bookmark options via `securityScoped: false`. See
    /// `MailDirectoryBookmarkTests` for why the fallback exists and what it
    /// does and doesn't prove.
    public static func create(for url: URL, securityScoped: Bool = true) throws -> MailDirectoryBookmark {
        let options: URL.BookmarkCreationOptions = securityScoped ? [.withSecurityScope] : []
        let data = try url.bookmarkData(options: options,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        return MailDirectoryBookmark(data: data)
    }

    /// Resolves this bookmark back to a `URL`. `isStale` is handed back
    /// rather than silently re-resolved — a caller that cares (re-picking the
    /// directory) can act on it; one that doesn't can ignore it exactly as
    /// before.
    public func resolve(securityScoped: Bool = true) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let options: URL.BookmarkResolutionOptions = securityScoped ? [.withSecurityScope] : []
        let url = try URL(resolvingBookmarkData: data, options: options,
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// Starts scoped access to a resolved URL; returns whether it succeeded
    /// (mirrors `URL.startAccessingSecurityScopedResource()`'s own `Bool`).
    /// Every call must be paired with `stopAccessing`.
    public static func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public static func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
