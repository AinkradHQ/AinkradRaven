import Foundation

/// Writes one fetched attachment's bytes to a throwaway temp file so
/// `QLPreviewPanel` (which previews a `URL`, not raw bytes) has something to
/// point at, and removes it again once the preview is done with it.
///
/// The plugin has no cache directory of its own — per the M0 design,
/// attachment bytes are held only for the open thread and never written to
/// disk unprompted. A QuickLook preview is a real exception (QuickLook needs
/// a file), so the file lives under a dedicated subdirectory of the system
/// temp directory and is deleted as soon as the panel closes — never left
/// behind indefinitely the way a stray "mail attachment" in `/tmp` would be.
public struct AttachmentPreviewFile {
    public let url: URL

    /// Writes `data` under `NSTemporaryDirectory()/RavenAttachmentPreviews/
    /// <uuid>/<filename>` — a fresh UUID subdirectory per preview so two
    /// attachments sharing a filename (e.g. two "invoice.pdf"s in the same
    /// thread) never collide on the same path.
    public init(data: Data, filename: String) throws {
        let directory = Self.previewRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename.isEmpty ? "attachment" : filename)
        try data.write(to: fileURL)
        self.url = fileURL
    }

    static let previewRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("RavenAttachmentPreviews", isDirectory: true)

    /// Removes this preview's file AND its per-preview UUID directory —
    /// called when the preview panel closes. Best-effort: a failure here
    /// (file already gone, permissions) must not crash or surface an error
    /// to the user, since nothing about the mail flow depends on it.
    public func cleanUp() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
