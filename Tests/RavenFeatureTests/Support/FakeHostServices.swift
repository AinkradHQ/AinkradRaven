import Foundation
import SwiftUI
import AinkradAppKit
@testable import RavenFeature

/// Builds a `HostThemeTokens` snapshot with the given theme id. Nothing under
/// test in this file reads color values, so black stands in for all of them.
func testTokens(themeID: String = "test") -> HostThemeTokens {
    HostThemeTokens(themeID: themeID, background: .black, surface: .black, surfaceElevated: .black,
                    accentPrimary: .black, accentSecondary: .black, accentTertiary: .black, foreground: .black)
}

/// Records every context source registered against it, so tests can assert
/// the registration count and invoke the registered closure — and, crucially
/// for the teardown tests, assert it was removed again.
@MainActor
final class RecordingContextRegistry: PluginContextRegistry {
    private(set) var sources: [PluginContextToken: @MainActor () -> AgentContextSnapshot?] = [:]
    func register(_ source: @escaping @MainActor () -> AgentContextSnapshot?) -> PluginContextToken {
        let token = PluginContextToken()
        sources[token] = source
        return token
    }
    func remove(_ token: PluginContextToken) { sources[token] = nil }
    /// Convenience: the snapshots all currently-registered sources produce.
    func snapshots() -> [AgentContextSnapshot] { sources.values.compactMap { $0() } }
}

/// Records every gated action handler registered against it, so tests can
/// assert registration counts, invoke a handler by action id, and assert
/// removal on teardown.
@MainActor
final class RecordingActionRegistry: AgentActionProvider {
    private(set) var handlers: [AgentActionToken: (String) async -> AgentActionResult] = [:]
    private(set) var ids: [AgentActionToken: String] = [:]
    func register(actionID: String,
                  handler: @escaping @MainActor (String) async -> AgentActionResult) -> AgentActionToken {
        let token = AgentActionToken()
        handlers[token] = handler
        ids[token] = actionID
        return token
    }
    func remove(_ token: AgentActionToken) { handlers[token] = nil; ids[token] = nil }
    func invoke(actionID: String, input: String) async -> AgentActionResult? {
        guard let token = ids.first(where: { $0.value == actionID })?.key,
              let handler = handlers[token] else { return nil }
        return await handler(input)
    }
}

private final class FakeLogger: PluginLogger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}
private final class FakeAppLauncher: PluginAppLauncher {
    func open(appID: String, payload: String?) {}
    func takePendingLaunch() -> String? { nil }
}
private final class FakePresentationControl: PluginPresentationControl {
    private(set) var current: PluginPresentation = .pane
    func set(_ presentation: PluginPresentation) { current = presentation }
    func reset() { current = .pane }
}

/// A minimal reference-type `HostServices` for registration/teardown tests.
/// Only `context`/`actions` carry behavior; the rest are inert doubles.
/// Reference type so `ObjectIdentifier(host as AnyObject)` gives it stable
/// identity, matching how `RavenApp.instance(of:)` keys a legacy host.
@MainActor
final class FakeHostServices: HostServices {
    // Real (in-memory) persistence, not a no-op stub: `RavenRuntime` builds
    // its `DocumentMailStore` straight off `host.documents`, and the sync
    // timer tests save an account/thread through `runtime.store` and need it
    // to actually read back — a no-op store would silently make every
    // `accounts()`/`thread(_:)` lookup return empty, masking real bugs behind
    // a store that looks connected but never retains anything.
    let documents: PluginDocumentStore = InMemoryDocumentStore()
    let secrets: PluginSecretStore = InMemorySecretStore()
    let theme: HostTheme = HostTheme(testTokens())
    let log: PluginLogger = FakeLogger()
    let apps: PluginAppLauncher = FakeAppLauncher()
    let presentation: PluginPresentationControl = FakePresentationControl()
    /// Generation 9. A no-op: these tests are about Raven, not about what the
    /// host does with an event.
    let signals: PluginSignalEmitter = NoopSignalEmitter()
    let context: PluginContextRegistry
    let actions: AgentActionProvider

    /// Keeps every fake host alive for the whole test process — see
    /// `RavenRuntime`'s per-instance cache: a short-lived fake host that
    /// deallocated could have its address reused by a later test, colliding
    /// with a stale legacy-identity entry and defeating register-once.
    private static var liveInstances: [FakeHostServices] = []

    init(context: PluginContextRegistry = RecordingContextRegistry(),
         actions: AgentActionProvider = RecordingActionRegistry()) {
        self.context = context
        self.actions = actions
        Self.liveInstances.append(self)
    }
}
