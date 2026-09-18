import Testing
import SwiftUI
import AinkradAppKit
@testable import RavenFeature

/// Raven's basic mode: read the inbox, open a thread. No composing.
@Suite("Raven — basic mode")
@MainActor
struct RavenBasicModeTests {

    @Test("Raven opts into modes, so the host's cast finds it")
    func optsIntoModes() {
        #expect((RavenApp.self as Any) as? AinkradAppModes.Type != nil)
    }

    @Test("Both modes build, and share one runtime")
    func bothModesShareTheRuntime() {
        // `RavenRuntime` eagerly builds the mail store, outbox, view model,
        // provider router and appearance store. Switching modes must not build
        // a second set — that would mean two views of the same mailbox, each
        // with its own sync state.
        let host = FakeHostServices(context: RecordingContextRegistry())
        _ = RavenApp.makeRootView(host: host, mode: .basic)
        _ = RavenApp.makeRootView(host: host, mode: .advanced)
        #expect(RavenApp.runtime(host: host) === RavenApp.runtime(host: host))
    }

    @Test("A Reply pressed in basic survives the escalation to advanced")
    func replyCarriesAcrossTheModeSwitch() {
        // The bug this guards, which shipped once: basic dropped the
        // ComposeContext on the claim advanced would re-derive it. It does not
        // — `RavenShell.composing` starts nil — so Reply landed you in the
        // advanced inbox with NO composer and nothing to say why.
        let host = FakeHostServices(context: RecordingContextRegistry())
        let runtime = RavenApp.runtime(host: host)

        runtime.pendingCompose = .new
        #expect(runtime.takePendingCompose() != nil, "advanced must find the request")
        #expect(runtime.takePendingCompose() == nil, "and it is consumed exactly once")
    }

    @Test("With nothing pending, advanced opens with no composer")
    func noPendingComposeOpensClean() {
        // The other half: a plain switch to advanced must not raise a composer
        // out of a stale request.
        let host = FakeHostServices(context: RecordingContextRegistry())
        #expect(RavenApp.runtime(host: host).takePendingCompose() == nil)
    }

    @Test("The mode-less entry point still means advanced")
    func legacyEntryPointMeansAdvanced() {
        _ = RavenApp.makeRootView(host: FakeHostServices(context: RecordingContextRegistry()))
    }
}
