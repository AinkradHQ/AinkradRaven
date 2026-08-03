import Testing
import Foundation
@testable import RavenFeature

/// Round-trips bookmark data against a TEMP DIRECTORY created for this test
/// — never `~/Library/Mail`.
///
/// `.withSecurityScope` requires an App Sandbox entitlement Mail.app's real
/// directory needs but this CLI test process does not have; creating a
/// security-scoped bookmark outside a sandbox is documented to throw. So
/// this test exercises the plain (non-security-scoped) bookmark path, which
/// is the same `URL.bookmarkData`/`URL(resolvingBookmarkData:)` machinery
/// `MailDirectoryBookmark` uses — only the `.withSecurityScope` option
/// differs, and that option is exactly what production code
/// (`MailDirectoryBookmark.create`/`resolve`, defaulted to `securityScoped:
/// true`) still requests. This is a real coverage gap for the sandboxed
/// path specifically, noted in the task report rather than papered over.
@Suite("MailDirectoryBookmark")
struct MailDirectoryBookmarkTests {
    @Test("plain bookmark data round-trips to the same directory")
    func roundTripsPlainBookmark() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailDirectoryBookmarkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bookmark = try MailDirectoryBookmark.create(for: tempDir, securityScoped: false)
        #expect(!bookmark.data.isEmpty)

        let resolved = try bookmark.resolve(securityScoped: false)
        #expect(resolved.url.standardizedFileURL == tempDir.standardizedFileURL)
        #expect(resolved.isStale == false)
    }

    @Test("start/stopAccessing are safe to call even on a non-scoped URL")
    func startStopAccessingIsSafe() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailDirectoryBookmarkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Outside a real security scope this simply returns false rather
        // than crashing — proven here so a caller can rely on it as a safe
        // no-op in a non-sandboxed context (like this test run).
        _ = MailDirectoryBookmark.startAccessing(tempDir)
        MailDirectoryBookmark.stopAccessing(tempDir)
    }
}
