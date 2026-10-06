import AinkradAppKit
import AppKit
import UniformTypeIdentifiers

/// Picks files to attach.
///
/// `NSOpenPanel`, allowing multiple selection of any file type — Compose does
/// not restrict which files can be attached, matching every other mail client.
/// Reads each picked file's bytes into memory immediately (never a cache
/// directory) and derives its MIME type from the file's extension via `UTType`,
/// falling back to `application/octet-stream` for a type `UTType` cannot
/// classify. A file that cannot be read is logged and returned in `skipped`
/// (by file name) so the composer can say so instead of dropping it silently.
enum ComposeAttachmentPicker {
    @MainActor static func pick() -> (picked: [OutgoingAttachment], skipped: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return ([], []) }
        var picked: [OutgoingAttachment] = []
        var skipped: [String] = []
        for url in panel.urls {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                AinkradLog.logger("raven.mime").error(
                    "Could not read attachment \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                skipped.append(url.lastPathComponent)
                continue
            }
            let mimeType =
                UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            picked.append(
                OutgoingAttachment(
                    filename: url.lastPathComponent,
                    mimeType: mimeType, data: data))
        }
        return (picked, skipped)
    }
}
