import AinkradAppKit
import AinkradAppKitUI
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RavenFeature

/// Glass Native E5: Raven's screens rendered under the standard (Neon) skin and
/// under the catalog's Liquid Glass theme + scheme, written as
/// `<dir>/raven-<screen>-neon.png` / `-glass.png`. A tool, not a check: it runs
/// only with AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR (the catalog's `themes/`)
/// set, and skips loudly otherwise.
@Suite("Raven glass sweep", .serialized)
@MainActor
struct GlassSweepTests: MultiAccountFixtures {
    @Test("shoot Raven's screens under Neon and Glass")
    func shoot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["AINKRAD_SWEEP_DIR"], let themes = env["AINKRAD_THEMES_DIR"] else {
            print("SKIPPED: set AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR — no Raven glass sweep")
            return
        }
        let glass = try Self.glassSkin(themes: URL(fileURLWithPath: themes))
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        let runtime = try seededRuntime()
        defer { runtime.teardown() }
        let appearance = runtime.appearanceStore.appearance
        let shots: [(String, CGSize, AnyView)] = [
            ("shell", CGSize(width: 1200, height: 720), AnyView(RavenShell(runtime: runtime))),
            (
                "rows", CGSize(width: 380, height: 260),
                AnyView(
                    VStack(spacing: 4) {
                        InboxRow(
                            summary: summary("Selected thread", unread: 0), isSelected: true, isUnread: false,
                            appearance: appearance, accountLabel: nil, rowError: nil, onTap: {})
                        InboxRow(
                            summary: summary("Unread thread", unread: 2), isSelected: false, isUnread: true,
                            appearance: appearance, accountLabel: "Work", rowError: nil, onTap: {})
                        InboxRow(
                            summary: summary("Read thread", unread: 0), isSelected: false, isUnread: false,
                            appearance: appearance, accountLabel: nil, rowError: "Not synced", onTap: {})
                    }
                    .padding()
                    .ravenAppearanceEnvironment(appearance))
            ),
            (
                "compose", CGSize(width: 820, height: 560),
                AnyView(ComposeSurface(runtime: runtime).ravenAppearanceEnvironment(appearance))
            ),
            (
                "section-frame", CGSize(width: 420, height: 160),
                AnyView(
                    RavenSectionFrame(title: "Drafts") { Text("A titled block") }
                        .padding()
                        .ravenAppearanceEnvironment(appearance))
            ),
            (
                "modal", CGSize(width: 900, height: 520),
                AnyView(
                    RavenShell(runtime: runtime)
                        .ravenTranslucentModal(
                            isPresented: .constant(true), contentWidth: 560, appearance: appearance
                        ) {
                            Text("Composer").frame(maxWidth: .infinity, minHeight: 240)
                        })
            ),
        ]
        for (name, size, view) in shots {
            for (theme, skin) in [("neon", AinkradSkin.standard), ("glass", glass)] {
                try LiveGlassCapture.shoot(
                    view
                        .frame(width: size.width, height: size.height)
                        .background(skin.color(skin.palette.background))
                        .ainkradSkin(skin)
                        .environment(\.colorScheme, .dark),
                    size: size,
                    to: URL(fileURLWithPath: out).appendingPathComponent("raven-\(name)-\(theme).png"))
            }
        }
    }

    /// One account, four threads (one unread, one selected with two messages).
    private func seededRuntime() throws -> RavenRuntime {
        let runtime = RavenRuntime(host: FakeHostServices())
        runtime.teardown()
        try runtime.store.saveAccount(
            MailAccount(
                id: "a1", provider: .gmail, address: "ahmed@example.com", displayName: "Ahmed",
                syncCursor: "c", state: .ready))
        let now = Date()  // the inbox lists recent months only
        try runtime.store.upsertThread(
            MailThread(
                id: "t1", accountID: "a1",
                messages: [
                    MailMessage(
                        id: "m1", threadID: "t1", from: MailAddress(email: "lina@example.com", name: "Lina"),
                        subject: "Liquid Glass review", date: now.addingTimeInterval(-3600), isRead: true,
                        labelIDs: ["INBOX"], snippet: "The island looks great — one note on the drift."),
                    MailMessage(
                        id: "m2", threadID: "t1", from: MailAddress(email: "ahmed@example.com", name: "Ahmed"),
                        subject: "Re: Liquid Glass review", date: now, isRead: true, labelIDs: ["INBOX"],
                        snippet: "Thanks, fixed: it moves as one piece now."),
                ]))
        try runtime.store.upsertThread(
            thread("t2", account: "a1", subject: "Build failed on main", date: now.addingTimeInterval(-60), unread: true))
        try runtime.store.upsertThread(
            thread("t3", account: "a1", subject: "Weekly summary", date: now.addingTimeInterval(-86_400)))
        try runtime.store.upsertThread(
            thread("t4", account: "a1", subject: "Invoice #1042", date: now.addingTimeInterval(-172_800)))
        runtime.model.reload()
        runtime.model.select("t1")
        return runtime
    }

    private func summary(_ subject: String, unread: Int) -> ThreadSummary {
        ThreadSummary(
            id: "s-\(subject)", accountID: "a1", subject: subject,
            participants: [MailAddress(email: "lina@example.com", name: "Lina")],
            lastMessageDate: Date(timeIntervalSinceReferenceDate: 800_000_000), messageCount: 2,
            unreadCount: unread, isStarred: false, labelIDs: ["INBOX"],
            snippet: "A two-line snippet that is long enough to wrap onto its second line in the rail.")
    }

    /// `glass-dark.theme` on the standard skin, coloured by `glass-dark.scheme`,
    /// composed the way the host's `ThemeCatalog.compose` does.
    static func glassSkin(themes: URL) throws -> AinkradSkin {
        let dir = themes.appendingPathComponent("glass")
        let base = try JSONEncoder().encode(AinkradSkin.standard)
        let theme = try Data(contentsOf: dir.appendingPathComponent("glass-dark.theme"))
        let variant = try #require(ainkradLoadThemes([base, theme]).themes["glass.dark"])
        var scheme = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("glass-dark.scheme")))
                as? [String: Any])
        scheme.removeValue(forKey: "appearance")
        scheme.removeValue(forKey: "host")
        scheme["base"] = "glass.dark"
        let data = try JSONSerialization.data(withJSONObject: scheme)
        return try AinkradThemeFile(decoding: data, bases: ["glass.dark": variant]).skin
    }
}

/// Off-screen `cacheDisplay` cannot draw Liquid Glass, so each shot is a real
/// window at desktop level (behind every window, no focus taken), claiming key
/// appearance so tints render, captured with `screencapture -l`. When the test
/// host cannot capture (no Screen Recording grant) a request file is answered
/// by the workspace's `.build/capture-broker.sh`.
@MainActor
enum LiveGlassCapture {
    private final class KeyAppearancePanel: NSPanel {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        @objc var hasKeyAppearance: Bool { true }
        @objc var hasMainAppearance: Bool { true }
        @objc var _hasActiveAppearance: Bool { true }
        @objc var _hasActiveAppearanceIgnoringKeyFocus: Bool { true }
    }

    static func shoot(_ view: some View, size: CGSize, to url: URL) throws {
        let panel = KeyAppearancePanel(
            contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.contentView = NSHostingView(
            rootView:
                view
                .environment(\.ainkradMotionBudget, .frozen)
                .environment(\.controlActiveState, .key))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        try? FileManager.default.removeItem(at: url)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { return }

        let requests = url.deletingLastPathComponent().appendingPathComponent(".requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try "\(panel.windowNumber) \(url.path)".write(
            to: requests.appendingPathComponent(UUID().uuidString + ".req"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "no capture for \(url.lastPathComponent)")
    }
}
