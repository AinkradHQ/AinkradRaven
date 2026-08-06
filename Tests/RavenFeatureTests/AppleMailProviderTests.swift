import Testing
import Foundation
@testable import RavenFeature

@Suite("AppleMailProvider")
@MainActor struct AppleMailProviderTests {
    /// Builds one well-formed `.emlx` file at `path`. Never touches
    /// `~/Library/Mail` — every call site here targets a temp directory this
    /// test itself created.
    private func writeEmlx(rfc822: String, isRead: Bool, to path: URL) throws {
        let messageBytes = Data(rfc822.utf8)
        var data = Data("\(messageBytes.count)\n".utf8)
        data.append(messageBytes)
        data.append(try PropertyListSerialization.data(
            fromPropertyList: ["flags": ["read": isRead]], format: .xml, options: 0))
        try data.write(to: path)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleMailProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("declares read-only capability")
    func declaresReadOnly() {
        let provider = AppleMailProvider(accountID: "am1", directory: URL(fileURLWithPath: "/dev/null"))
        #expect(provider.capabilities == .readOnly)
    }

    @Test("send refuses directly against the provider, not only at the router")
    func sendRefusesDirectly() async throws {
        let provider = AppleMailProvider(accountID: "am1", directory: URL(fileURLWithPath: "/dev/null"))
        await #expect(throws: MailError.readOnlyAccount("am1")) {
            _ = try await provider.send(OutgoingMessage(to: [MailAddress(email: "a@b.com")],
                                                        subject: "s", bodyText: "b"))
        }
    }

    @Test("applyLabels refuses directly against the provider")
    func applyLabelsRefusesDirectly() async throws {
        let provider = AppleMailProvider(accountID: "am1", directory: URL(fileURLWithPath: "/dev/null"))
        await #expect(throws: MailError.readOnlyAccount("am1")) {
            try await provider.applyLabels(LabelMutation(threadIDs: ["t1"], remove: ["INBOX"]))
        }
    }

    @Test("fetchThreads reads a real imported+threaded reply chain from a temp directory")
    func fetchThreadsReadsImportedMail() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeEmlx(rfc822: """
        Subject: Original\r
        From: alice@example.com\r
        Message-ID: <a1@example.com>\r
        Date: Mon, 1 Jan 2024 10:00:00 +0000\r
        \r
        First message.\r
        """, isRead: true, to: dir.appendingPathComponent("1.emlx"))

        try writeEmlx(rfc822: """
        Subject: Re: Original\r
        From: bob@example.com\r
        Message-ID: <a2@example.com>\r
        In-Reply-To: <a1@example.com>\r
        References: <a1@example.com>\r
        Date: Mon, 1 Jan 2024 11:00:00 +0000\r
        \r
        Reply message.\r
        """, isRead: false, to: dir.appendingPathComponent("2.emlx"))

        let provider = AppleMailProvider(accountID: "am1", directory: dir)
        let page = try await provider.fetchThreads(since: .distantPast, pageToken: nil)

        #expect(page.threads.count == 1)
        #expect(page.threads.first?.messages.count == 2)
        #expect(page.nextPageToken == nil)
    }

    @Test("Apple Mail import is refused by the router the same way any read-only provider is")
    func routedThroughRouterRefusesWrite() async throws {
        let provider = AppleMailProvider(accountID: "am1", directory: URL(fileURLWithPath: "/dev/null"))
        let router = MailProviderRouter()
        router.attach(provider, accountID: "am1")
        #expect(throws: MailError.readOnlyAccount("am1")) {
            _ = try router.writableProvider(for: "am1")
        }
    }
}
