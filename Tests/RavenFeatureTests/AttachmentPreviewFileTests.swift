import Testing
import Foundation
@testable import RavenFeature

/// The QuickLook preview path writes one temp file per preview (QuickLook
/// previews a `URL`, not raw bytes) and must remove it again — the plugin
/// has no cache directory, and a mail attachment left behind in the system
/// temp directory indefinitely is exactly the failure mode this guards.
@Suite("Attachment preview temp file")
struct AttachmentPreviewFileTests {
    @Test("the temp file is written with the attachment's bytes and filename")
    func writesFile() throws {
        let data = Data("hello preview".utf8)
        let file = try AttachmentPreviewFile(data: data, filename: "note.txt")
        defer { file.cleanUp() }
        #expect(file.url.lastPathComponent == "note.txt")
        #expect(try Data(contentsOf: file.url) == data)
    }

    @Test("cleanUp removes the file and its per-preview directory")
    func cleanUpRemovesFile() throws {
        let file = try AttachmentPreviewFile(data: Data("bytes".utf8), filename: "a.pdf")
        let directory = file.url.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        file.cleanUp()
        #expect(FileManager.default.fileExists(atPath: file.url.path) == false)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    }

    @Test("two previews of files sharing a filename do not collide")
    func distinctPreviewsDoNotCollide() throws {
        let first = try AttachmentPreviewFile(data: Data("one".utf8), filename: "same.txt")
        let second = try AttachmentPreviewFile(data: Data("two".utf8), filename: "same.txt")
        defer { first.cleanUp(); second.cleanUp() }
        #expect(first.url != second.url)
        #expect(try Data(contentsOf: first.url) == Data("one".utf8))
        #expect(try Data(contentsOf: second.url) == Data("two".utf8))
    }
}
