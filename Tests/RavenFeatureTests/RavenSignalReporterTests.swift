import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

@MainActor
@Suite("Raven signal reporting")
struct RavenSignalReporterTests {
    final class RecordingEmitter: PluginSignalEmitter {
        struct Call {
            let kind: String
            let severity: SignalSeverity
            let title: String
            let body: String?
            let importance: SignalImportance
            let dedupeKey: String?
        }
        private(set) var calls: [Call] = []
        func emit(kind: String, severity: SignalSeverity, title: String, body: String?,
                  importance: SignalImportance, deepLink: SignalDeepLink?,
                  actions: [SignalAction], dedupeKey: String?) {
            calls.append(Call(kind: kind, severity: severity, title: title, body: body,
                              importance: importance, dedupeKey: dedupeKey))
        }
        func own(limit: Int) -> [SignalEvent] { [] }
        func handleAction(_ actionID: String,
                          _ handler: @escaping @MainActor () async -> Void) -> AgentActionToken {
            AgentActionToken()
        }
        func removeActionHandler(_ token: AgentActionToken) {}
    }

    private func reporter() -> (RavenSignalReporter, RecordingEmitter) {
        let emitter = RecordingEmitter()
        return (RavenSignalReporter(signals: emitter), emitter)
    }

    @Test("a pass that brought in nothing says nothing")
    func emptyPassIsSilent() {
        let (reporter, emitter) = self.reporter()
        reporter.mailArrived(count: 0, accountLabel: "work@example.com")
        #expect(emitter.calls.isEmpty, "a sync that found no mail is not news")
    }

    @Test("new mail is one event carrying a count, not one event per thread")
    func mailArrivedIsSingular() {
        let (reporter, emitter) = self.reporter()
        reporter.mailArrived(count: 40, accountLabel: "work@example.com")
        #expect(emitter.calls.count == 1, "forty rows would bury everything else in the feed")
        #expect(emitter.calls[0].title == "40 new messages")
        #expect(emitter.calls[0].kind == "mail.arrived")
        #expect(emitter.calls[0].severity == .info)
    }

    @Test("a single message is not pluralised")
    func singularWording() {
        let (reporter, emitter) = self.reporter()
        reporter.mailArrived(count: 1, accountLabel: "work@example.com")
        #expect(emitter.calls[0].title == "New message")
    }

    @Test("auth failure is the one urgent Raven event")
    func authFailureIsUrgent() {
        let (reporter, emitter) = self.reporter()
        reporter.authenticationFailed(accountLabel: "work@example.com")
        #expect(emitter.calls[0].kind == "account.auth-failed")
        #expect(emitter.calls[0].severity == .failure)
        #expect(emitter.calls[0].importance == .urgent,
                "mail silently stops until this is dealt with")
    }

    @Test("a transient sync failure is a warning, not a failure")
    func syncFailureIsAWarning() {
        let (reporter, emitter) = self.reporter()
        reporter.syncFailed(accountLabel: "work@example.com", reason: "rate limited")
        #expect(emitter.calls[0].kind == "sync.failed")
        #expect(emitter.calls[0].severity == .warning,
                "these retry on the next pass; crying failure trains the user to ignore them")
        #expect(emitter.calls[0].importance == .normal)
        #expect(emitter.calls[0].body == "rate limited")
    }

    @Test("dedupe keys are per account, so two accounts do not collide")
    func dedupeKeysArePerAccount() {
        let (reporter, emitter) = self.reporter()
        reporter.mailArrived(count: 1, accountLabel: "a@example.com")
        reporter.mailArrived(count: 1, accountLabel: "b@example.com")
        #expect(emitter.calls[0].dedupeKey != emitter.calls[1].dedupeKey)
    }

    @Test("the three kinds are distinct, so a user can mute one and keep the others")
    func kindsAreSeparable() {
        let (reporter, emitter) = self.reporter()
        reporter.mailArrived(count: 1, accountLabel: "a")
        reporter.authenticationFailed(accountLabel: "a")
        reporter.syncFailed(accountLabel: "a", reason: "x")
        #expect(Set(emitter.calls.map(\.kind)).count == 3)
    }

    @Test("every kind Raven emits is one the host will accept")
    func kindsAreValid() {
        let (reporter, emitter) = self.reporter()
        reporter.mailArrived(count: 1, accountLabel: "a")
        reporter.authenticationFailed(accountLabel: "a")
        reporter.syncFailed(accountLabel: "a", reason: "x")
        // The host rejects an invalid kind SILENTLY. Assert, do not assume.
        for call in emitter.calls {
            #expect(SignalKind.isValid(call.kind), "invalid kind: \(call.kind)")
        }
    }
}

@Suite("Sync failure classification")
struct RavenSyncFailureClassificationTests {
    /// `SyncState.failed` carries only a String — `String(describing: error)`
    /// from the engine — so telling "needs re-authentication" from "the network
    /// blipped" means matching on that description.
    ///
    /// That is fragile, and this test is what makes it safe: if `MailError`'s
    /// description ever stops containing `notAuthenticated`, this fails here
    /// rather than silently downgrading an urgent "sign in again" to a routine
    /// sync warning the user learns to ignore.
    @Test("an auth error's description still carries the marker the runtime matches on")
    func authErrorIsRecognisable() {
        let described = String(describing: MailError.notAuthenticated(accountID: "acct"))
        #expect(described.contains("notAuthenticated"))
    }

    @Test("a transient provider failure does NOT look like an auth failure")
    func transientErrorIsNotAuth() {
        let described = String(describing: MailError.providerFailed(status: 503, message: "busy"))
        #expect(!described.contains("notAuthenticated"),
                "or every rate limit would tell the user to sign in again")
        #expect(!String(describing: MailError.rateLimited(retryAfter: 30))
            .contains("notAuthenticated"))
    }
}
