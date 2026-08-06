import Testing
import Foundation
@testable import RavenFeature

@Suite("AppleMailImporter")
@MainActor struct AppleMailImporterTests {
    private func writeEmlx(subject: String, isRead: Bool, to path: URL) throws {
        let rfc822 = "Subject: \(subject)\r\nFrom: a@x.com\r\nMessage-ID: <\(UUID().uuidString)@x.com>\r\n\r\nbody"
        let messageBytes = Data(rfc822.utf8)
        var data = Data("\(messageBytes.count)\n".utf8)
        data.append(messageBytes)
        data.append(try PropertyListSerialization.data(
            fromPropertyList: ["flags": ["read": isRead]], format: .xml, options: 0))
        try data.write(to: path)
    }

    @Test("importAll reports progress via the same SyncState/onChange shape SyncEngine uses")
    func reportsProgressLikeSyncEngine() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleMailImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<5 {
            try writeEmlx(subject: "s\(index)", isRead: true, to: dir.appendingPathComponent("\(index).emlx"))
        }

        let importer = AppleMailImporter(accountID: "am1")
        var sawBackfilling = false
        importer.onChange = { [weak importer] in
            if case .backfilling = importer?.state { sawBackfilling = true }
        }

        let threads = try await importer.importAll(from: dir)
        #expect(threads.count == 5)
        #expect(sawBackfilling)
        #expect(importer.state == .idle)
    }

    @Test("a cancelled import stops rather than running to completion")
    func respectsCancellation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleMailImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<10 {
            try writeEmlx(subject: "s\(index)", isRead: true, to: dir.appendingPathComponent("\(index).emlx"))
        }

        let importer = AppleMailImporter(accountID: "am1")
        let task = Task { try await importer.importAll(from: dir) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
