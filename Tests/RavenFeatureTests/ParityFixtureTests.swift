import AinkradAppKit
import Foundation
import Testing

@testable import RavenFeature

/// Builds one fake mail account through the real `DocumentMailStore` so a Debug
/// host can be seeded with a populated inbox for before/after screenshot capture.
///
/// No network, no keychain, no token: the store is in memory and the account is
/// `.gmail` with no stored credentials, which still DISPLAYS from the synced
/// documents (a provider is only needed to sync or fetch a missing body, and the
/// fixture stores every body). Normal runs only prove the fixture builds and
/// reloads in memory. Files are written ONLY when `RAVEN_PARITY_FIXTURE_OUT=<dir>`
/// is set. Dates hang off `now`, so seed the host the same day it is run.
@Suite("ParityFixture")
@MainActor
struct ParityFixtureTests {
    static let accountID = "parity-fixture"
    static let me = MailAddress(email: "parity@fixture.invalid", name: "Parity Fixture")

    static func makeDocuments(now: Date = Date()) throws -> InMemoryDocumentStore {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func person(_ name: String) -> MailAddress {
            MailAddress(email: "\(name.lowercased())@fixture.invalid", name: name)
        }
        var seq = 0
        func message(
            _ thread: String, from: MailAddress?, subject: String, hoursAgo: Double,
            read: Bool = true, starred: Bool = false, snippet: String,
            attachments: [MailAttachment] = []
        ) -> MailMessage {
            seq += 1
            var labels = ["INBOX"]
            if !read { labels.append("UNREAD") }
            if starred { labels.append("STARRED") }
            return MailMessage(
                id: "m\(String(format: "%03d", seq))", threadID: thread,
                rfc822MessageID: "<m\(seq)@fixture.invalid>", from: from, to: [Self.me],
                subject: subject, date: ago(hoursAgo), isRead: read, isStarred: starred,
                labelIDs: labels, hasAttachments: !attachments.isEmpty, snippet: snippet,
                attachments: attachments)
        }

        let ada = person("Ada")
        let grace = person("Grace")
        let linus = person("Linus")
        let release = "Release notes for 0.27"
        let invoice = "Invoice 2026-114"
        let digest = "Weekly engineering digest"
        let planning = "Planning the next milestone"

        let threads: [(MailThread, [String: MessageBody])] = [
            // Unread, two messages, the newest unread.
            thread(
                "t-unread",
                [
                    message(
                        "t-unread", from: ada, subject: planning, hoursAgo: 30,
                        snippet: "Can we agree on the order before Friday?"),
                    message(
                        "t-unread", from: Self.me, subject: "Re: \(planning)", hoursAgo: 28,
                        snippet: "Order is fine with me, shipping last."),
                    message(
                        "t-unread", from: ada, subject: "Re: \(planning)", hoursAgo: 2,
                        read: false, snippet: "Great, I will put it on the board now."),
                ]),
            // Starred, read, one message.
            thread(
                "t-starred",
                [
                    message(
                        "t-starred", from: grace, subject: release, hoursAgo: 44,
                        snippet: "First draft of the notes is below."),
                    message(
                        "t-starred", from: Self.me, subject: "Re: \(release)", hoursAgo: 40,
                        snippet: "Looks good, two small wording fixes."),
                    message(
                        "t-starred", from: grace, subject: "Re: \(release)", hoursAgo: 20, starred: true,
                        snippet: "Fixed, please star what you want kept."),
                ]),
            // Attachment chips: a PDF and an image.
            thread(
                "t-attach",
                [
                    message(
                        "t-attach", from: linus, subject: invoice, hoursAgo: 52,
                        snippet: "Sending the invoice over now."),
                    message(
                        "t-attach", from: linus, subject: "Re: \(invoice)", hoursAgo: 50, read: false,
                        snippet: "Invoice and the signed statement of work attached.",
                        attachments: [
                            MailAttachment(
                                attachmentID: "a1", filename: "invoice-2026-114.pdf",
                                mimeType: "application/pdf", size: 184_320),
                            MailAttachment(
                                attachmentID: "a2", filename: "statement-of-work.png",
                                mimeType: "image/png", size: 2_411_008),
                        ]),
                ]),
            // One long HTML body.
            thread(
                "t-long",
                [
                    message(
                        "t-long", from: person("Margaret"), subject: digest, hoursAgo: 80,
                        snippet: "Eight sections, two tables and a long list of merged changes."),
                    message(
                        "t-long", from: person("Margaret"), subject: digest, hoursAgo: 8,
                        snippet: "Eight sections, two tables and a long list of merged changes."),
                ]),
        ]

        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        try store.saveAccount(
            MailAccount(
                id: accountID, provider: .gmail, address: Self.me.email,
                displayName: "Parity Fixture", state: .ready, lastSyncedAt: ago(0.1)))
        try store.saveLabels(
            [
                MailLabel(id: "INBOX", name: "Inbox", kind: .system),
                MailLabel(id: "UNREAD", name: "Unread", kind: .system),
                MailLabel(id: "STARRED", name: "Starred", kind: .system),
            ], accountID: accountID)
        for (thread, bodies) in threads {
            try store.upsertThread(thread)
            for body in bodies.values { try store.saveBody(body, accountID: accountID) }
        }
        return documents
    }

    private static func thread(_ id: String, _ messages: [MailMessage]) -> (MailThread, [String: MessageBody]) {
        var bodies: [String: MessageBody] = [:]
        for message in messages {
            bodies[message.id] = body(for: message, long: id == "t-long")
        }
        return (MailThread(id: id, accountID: accountID, messages: messages), bodies)
    }

    private static func body(for message: MailMessage, long: Bool) -> MessageBody {
        guard long else {
            let text = "\(message.snippet)\n\nThanks,\n\(message.from?.displayLabel ?? "")"
            return MessageBody(
                messageID: message.id, plainText: text,
                html: "<p>\(message.snippet)</p><p>Thanks,<br>\(message.from?.displayLabel ?? "")</p>")
        }
        let sections = (1...8).map { n in
            """
            <h2>Section \(n): area \(n) changes</h2>
            <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Merged work this week touched \
            the sync engine, the thread surface and the compose sheet, with the usual fixes to keep \
            long lines wrapping and quoted text collapsing correctly.</p>
            <ul><li>Fix wrapping of very long subjects in the inbox rail</li>\
            <li>Keep the unread dot aligned with the sender line</li>\
            <li>Collapse quoted replies by default</li></ul>
            <table border="1" cellpadding="4"><tr><th>Metric</th><th>Value</th></tr>\
            <tr><td>Merged PRs</td><td>\(n * 7)</td></tr><tr><td>Open issues</td><td>\(40 - n)</td></tr></table>
            """
        }.joined(separator: "\n")
        return MessageBody(
            messageID: message.id,
            plainText: (1...8).map { "Section \($0): area \($0) changes. Merged work this week." }
                .joined(separator: "\n\n"),
            html: "<html><body><h1>Weekly engineering digest</h1>\n\(sections)</body></html>")
    }

    /// The host's `ScopedPluginDocumentStore` file name for a key.
    static func fileName(forKey key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_") + ".bin"
    }

    @Test("the fixture is one account, four threads, ten messages, and reloads")
    func fixtureShape() throws {
        let now = Date()
        let store = DocumentMailStore(documents: try Self.makeDocuments(now: now))

        #expect(store.accounts().map(\.address) == ["parity@fixture.invalid"])
        let rows = store.summaries(accountID: Self.accountID, months: UnifiedInbox.recentMonths(now: now))
        #expect(rows.count == 4)
        #expect(rows.map(\.messageCount).reduce(0, +) == 10)
        #expect(rows.filter { $0.unreadCount > 0 }.count == 2)
        #expect(rows.contains { $0.isStarred })
        let attach = try #require(store.thread("t-attach"))
        #expect(attach.messages.last?.attachments.count == 2)
        let long = try #require(store.thread("t-long"))
        let html = try #require(store.body(messageID: long.messages[0].id)?.html)
        #expect(html.count > 3000)
    }

    @Test("writes <key>.bin files only when RAVEN_PARITY_FIXTURE_OUT is set")
    func writeFixture() throws {
        guard let out = ProcessInfo.processInfo.environment["RAVEN_PARITY_FIXTURE_OUT"], !out.isEmpty
        else { return }
        let documents = try Self.makeDocuments()
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in documents.storage.keys.sorted() {
            let data = try #require(documents.data(forKey: key))
            try data.write(to: directory.appendingPathComponent(Self.fileName(forKey: key)))
        }
    }
}
