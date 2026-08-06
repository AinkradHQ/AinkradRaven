import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

@Suite("Published settings catalog")
@MainActor struct RavenSettingsCatalogTests {

    private func page(_ host: FakeHostServices = FakeHostServices()) -> SettingsPage {
        // Through `RavenApp`, not `RavenSettingsCatalog` directly: the thing
        // worth pinning is that the PROTOCOL requirement is satisfied. Calling
        // the builder directly would still pass if `RavenApp` had silently
        // fallen back to the `{ nil }` default extension.
        guard let page = RavenApp.settingsCatalog(host: host) else {
            Issue.record("RavenApp published no settings catalog")
            return SettingsPage(path: SettingsPath([]), title: "", icon: "",
                                group: .installedApps, order: 0, groups: [])
        }
        return page
    }

    // MARK: The tab bar the user asked for

    @Test("The page publishes enough groups that the host renders a tab bar")
    func tabsComeFromGroupCount() {
        let page = page()
        // The tabs are not built here; they are a consequence of group count.
        // `SettingsPageView.usesTabs` is the host-side rule, so assert against
        // it rather than against a copy of the number.
        #expect(SettingsPageView.usesTabs(page: page))
        #expect(page.groups.count >= 5)
    }

    @Test("The five named groups are present, in tab order")
    func groupsAreTheOnesSpecified() {
        #expect(page().groups.map(\.title)
                == ["Accounts", "Sending", "Rules", "Privacy", "Transparency"])
    }

    @Test("No group is titled Appearance, because the host appends its own")
    func noDuplicateAppearanceTab() {
        // `AppSettingsCatalog` appends a host-owned "Appearance" group (its
        // per-app blur toggle) to every plugin page. A group of ours with the
        // same title becomes a second identically-labelled tab, which is
        // unnavigable — hence "Transparency".
        #expect(!page().groups.contains { $0.title == "Appearance" })
    }

    @Test("Group titles are unique, so every tab is distinguishable")
    func tabTitlesAreUnique() {
        let titles = page().groups.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    // MARK: Paths

    @Test("Declared paths are relative, so the host's re-rooting does not double-prefix")
    func pathsAreRelative() {
        // `AppSettingsCatalog.namespaced` prefixes every group and field path
        // with ["app", "raven"]. Declaring that prefix ourselves — as the
        // plugin template does — yields app.raven.app.raven.*.
        let page = page()
        for group in page.groups {
            #expect(group.path.segments.first != "app")
            for field in group.fields {
                #expect(field.path.segments.first != "app")
                // And each field really does sit under its own group, which is
                // what survives the re-rooting and drives deep-linking.
                #expect(field.path.segments.starts(with: group.path.segments))
            }
        }
    }

    @Test("Every field path is unique across the page")
    func fieldPathsAreUnique() {
        // Duplicate paths collide in the host's search index, in
        // `catalog.field(at:)` and in highlight resolution.
        let paths = page().allFields.map(\.path)
        #expect(Set(paths).count == paths.count)
    }

    // MARK: Which fields earned `.custom`

    @Test("Only the genuinely non-declarative fields are custom")
    func customIsUsedSparingly() {
        let page = page()
        var customLabels: [String] = []
        for field in page.allFields {
            if case .custom = field.kind { customLabels.append(field.label) }
        }
        // The list of things that cannot be a label plus one control: the
        // attention queue (two lists of entries with per-entry discard), the
        // account list (variable-length, live badges, per-account destructive
        // action), the rules editor, and the image allow-list.
        #expect(customLabels.sorted() == [
            "Connected accounts", "Filter rules", "Needs your attention",
            "Senders allowed to load images"
        ])
    }

    @Test("Transparency and the undo window are declarative, never custom")
    func realControlsUseRealKinds() {
        let page = page()
        func kindName(_ label: String) -> String? {
            guard let field = page.allFields.first(where: { $0.label == label }) else { return nil }
            switch field.kind {
            case .toggle: return "toggle"
            case .select: return "select"
            case .slider: return "slider"
            case .text: return "text"
            case .secure: return "secure"
            case .shortcut: return "shortcut"
            case .action: return "action"
            case .custom: return "custom"
            // `SettingsFieldKind` is a non-frozen enum across the module
            // boundary, so a default is required even though every case above
            // is handled.
            @unknown default: return "unknown"
            }
        }
        #expect(kindName("Surface opacity") == "slider")
        #expect(kindName("Undo window") == "slider")
    }

    @Test("Every group carries prose in footerNote or in a self-chromed pane, never in labels")
    func proseIsNotCrammedIntoLabels() {
        for group in page().groups {
            let hasPane = group.fields.contains { field in
                if case .custom = field.kind { return true }
                return false
            }
            // A group is allowed to have no footerNote only when a `.custom`
            // pane is drawing its own explanation (Rules, Privacy).
            #expect(group.footerNote != nil || hasPane,
                    "group '\(group.title)' explains itself nowhere")
            // Labels stay short; the "why would I change this" paragraph
            // belongs in footerNote.
            for field in group.fields {
                #expect(field.label.count < 60, "label too long: \(field.label)")
            }
        }
    }

    // MARK: Behaviour that must not be lost in the restructure

    @Test("The sidebar badge counts the outbox entries needing a human")
    func badgeSurfacesTheAttentionQueue() {
        let page = page()
        // The host honours `badge` (unlike path/title/icon/group/order), so
        // this is the one piece of page metadata worth asserting. With nothing
        // queued it must be 0 — a badge that always shows trains people to
        // ignore it.
        #expect(page.badge != nil)
        #expect(page.badge?() == 0)
    }

    @Test("The undo window field reads, writes and resets the real hold window")
    func undoWindowIsWiredToTheSendPath() throws {
        let host = FakeHostServices()
        let runtime = RavenApp.runtime(host: host)
        let field = try #require(page(host).allFields.first { $0.label == "Undo window" })
        guard case .slider(let range, let step, let value) = field.kind else {
            Issue.record("Undo window is not a slider"); return
        }
        // Zero has to remain reachable — it is the documented "send immediately,
        // no undo" setting.
        #expect(range.contains(0))
        #expect(step > 0)

        #expect(value.wrappedValue == runtime.holdWindow)
        value.wrappedValue = 35
        #expect(runtime.holdWindow == 35)
        // Modified/reset are what drive the host's revert affordance.
        #expect(field.isModified())
        field.reset?()
        #expect(runtime.holdWindow == SendAttempt.defaultHoldWindow)
        #expect(!field.isModified())
    }

    @Test("The transparency field cannot write an illegible value through the binding")
    func transparencySliderRespectsTheFloor() throws {
        let host = FakeHostServices()
        let runtime = RavenApp.runtime(host: host)
        let field = try #require(page(host).allFields.first { $0.label == "Surface opacity" })
        guard case .slider(let range, _, let value) = field.kind else {
            Issue.record("Surface opacity is not a slider"); return
        }
        // The slider is not merely clamped on read — the range it OFFERS
        // already excludes the illegible band, so the control cannot express
        // the bad value in the first place.
        #expect(range == RavenAppearance.legibleRange)

        value.wrappedValue = range.lowerBound
        #expect(runtime.appearanceStore.appearance.surfaceOpacity == range.lowerBound)
        field.reset?()
        #expect(runtime.appearanceStore.appearance.surfaceOpacity
                == RavenAppearance.defaultSurfaceOpacity)
    }

    @Test("A signature field exists per sendable account and writes only to that account")
    func signaturesStayPerAccount() throws {
        let host = FakeHostServices()
        let runtime = RavenApp.runtime(host: host)
        try runtime.store.saveAccount(MailAccount(id: "a1", provider: .gmail,
                                                 address: "one@example.com",
                                                 displayName: "One"))
        try runtime.store.saveAccount(MailAccount(id: "a2", provider: .gmail,
                                                 address: "two@example.com",
                                                 displayName: "Two"))

        let fields = page(host).allFields.filter { $0.label.hasPrefix("Signature") }
        #expect(fields.count == 2)

        let first = try #require(fields.first { $0.label.contains("one@example.com") })
        guard case .text(let binding) = first.kind else {
            Issue.record("Signature is not a text field"); return
        }
        binding.wrappedValue = "Sent from one"
        // The bug this guards: a shared binding writing one account's signature
        // into whichever row rendered last.
        #expect(runtime.accounts.first { $0.id == "a1" }?.signature == "Sent from one")
        #expect(runtime.accounts.first { $0.id == "a2" }?.signature != "Sent from one")
        // And writing a signature must not disturb the sync bookkeeping on the
        // row — the stale-snapshot-writeback bug that used to re-backfill.
        #expect(runtime.accounts.first { $0.id == "a1" }?.lastSyncedAt == nil)
    }

    @Test("Read-only accounts get no signature field, because they cannot send")
    func readOnlyAccountsHaveNoSignature() throws {
        let host = FakeHostServices()
        let runtime = RavenApp.runtime(host: host)
        try runtime.store.saveAccount(MailAccount(id: "imported", provider: .gmail,
                                                 address: "old@example.com",
                                                 displayName: "Imported"))
        try runtime.store.saveAccount(MailAccount(id: "live", provider: .gmail,
                                                 address: "live@example.com",
                                                 displayName: "Live"))
        // Read-only is a property of the ATTACHED PROVIDER, not of the stored
        // account — an Apple Mail import has no transport. Only the imported
        // account gets one, so this also proves the filter is per-account and
        // not a blanket on/off.
        let readOnly = FakeMailProvider()
        readOnly.capabilities = .readOnly
        runtime.providers.attach(readOnly, accountID: "imported")
        runtime.providers.attach(FakeMailProvider(), accountID: "live")

        let fields = page(host).allFields.filter { $0.label.hasPrefix("Signature") }
        #expect(fields.count == 1)
        #expect(fields.first?.label.contains("live@example.com") == true)
    }

    @Test("Connect is refused until credentials are actually saved")
    func connectGateIsHonest() {
        let runtime = RavenApp.runtime(host: FakeHostServices())
        // Whichever way this build was made, the gate must agree with why:
        // baked-in credentials mean Connect works, nothing saved means it does
        // not. Enabled-but-guaranteed-to-fail is the state being avoided.
        #expect(runtime.canConnectAccount
                == (runtime.isCredentialsBaked || runtime.hasCredentials))
    }
}
