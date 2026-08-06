import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// The "not configured" state: no Azure app registration in this build.
///
/// The criterion is that this degrades to a clear, per-account failure —
/// the plugin loads and **every other account keeps working**.
@Suite("Graph not configured")
@MainActor
struct GraphNotConfiguredTests {
    private func account(_ id: String, kind: MailAccount.ProviderKind) -> MailAccount {
        MailAccount(id: id, provider: kind, address: "\(id)@example.test",
                    displayName: id, state: .ready)
    }

    /// An EMPTY credential slot: no baked Azure id (none is baked in any build
    /// today) and nothing saved in `host.documents`.
    @Test("with no Azure registration the factory reports not-configured rather than guessing")
    func emptyCredentialSlotIsNotConfigured() throws {
        let factory = ProviderFactory(host: FakeHostServices(), securityScopedBookmarks: false)
        #expect(factory.hasGraphCredentials == false)
        #expect(throws: MailError.notAuthenticated(accountID: "g1")) {
            _ = try factory.makeProvider(for: account("g1", kind: .graph))
        }
    }

    /// What a refusal must look like, and the outcome the race below reports.
    private enum AuthorizeOutcome: Equatable {
        case refused(MailError)
        case other(String)
        /// The interesting one: the call did not answer at all in time.
        case timedOut
    }

    /// Deadline-bounded deliberately, and the deadline is not theoretical: a
    /// regression that lets this reach `GraphAuth.authorize` puts the real
    /// loopback listener up and blocks for its full 180-second consent timeout.
    /// That was OBSERVED while mutation-testing this very assertion — a
    /// three-minute stall inside a fifteen-second run — so the refusal has to be
    /// fast, not merely eventual.
    ///
    /// The race is written over an `AsyncStream` rather than a task group on
    /// purpose: a task group awaits its children before returning, so a
    /// group-based deadline still pays the full 180 seconds even after it has
    /// recorded the failure. Breaking out of the stream terminates it, cancels
    /// both tasks, and lets the test finish at the deadline.
    @Test("a Connect attempt with no Azure registration refuses instead of opening a browser")
    func authorizeRefusesWhenNotConfigured() async throws {
        let factory = ProviderFactory(host: FakeHostServices(), securityScopedBookmarks: false)
        let stream = AsyncStream<AuthorizeOutcome> { continuation in
            let work = Task { @MainActor in
                do {
                    _ = try await factory.authorize(kind: .graph)
                    continuation.yield(.other("authorize succeeded with no registration"))
                } catch let error as MailError {
                    continuation.yield(.refused(error))
                } catch {
                    continuation.yield(.other("\(error)"))
                }
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(5))
                continuation.yield(.timedOut)
            }
            continuation.onTermination = { _ in work.cancel(); deadline.cancel() }
        }
        var outcome: AuthorizeOutcome?
        for await first in stream {
            outcome = first
            break
        }
        #expect(outcome == .refused(.notAuthenticated(accountID: "")),
                "expected an immediate refusal, got \(String(describing: outcome))")
    }

    /// **The credential must not outlive the sign-out that revoked it**, and
    /// the case that breaks is precisely the one this suite is about: no Azure
    /// registration, so there is no `GraphAuth` instance to ask.
    ///
    /// A token can be in the Keychain while `graphAuth` is `nil` — connect the
    /// account in a build that had a registration, then remove it (or ship a
    /// build without one). `signOut` must still clear it. Written as a *stored
    /// secret plus a factory that cannot construct Graph*, which is exactly
    /// what `graphAuth?.signOut(…)` silently skips.
    @Test("signing out clears the Graph refresh token even with no Azure registration")
    func signOutClearsRefreshTokenWithoutARegistration() throws {
        let host = FakeHostServices()
        let secrets = try #require(host.secrets as? InMemorySecretStore)
        secrets.setSecret("graph-refresh-secret", forKey: "graph-refresh-g1")
        secrets.setSecret("gmail-refresh-secret", forKey: "refresh-a1")

        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)
        // The precondition that makes this the interesting case, asserted
        // rather than assumed: there is no instance to route the clear through.
        #expect(factory.hasGraphCredentials == false)

        factory.signOut(accountID: "g1")

        #expect(secrets.secret(forKey: "graph-refresh-g1") == nil)
        // Exhaustive: nothing else was written, and — the scoping contract —
        // the OTHER account's token is untouched.
        #expect(secrets.allSecrets() == ["refresh-a1": "gmail-refresh-secret"])
    }

    /// The same clear, scoped: signing out of `g1` must not clear `g2`.
    @Test("signing out of one Graph account leaves another Graph account's token alone")
    func signOutIsScopedToOneAccount() throws {
        let host = FakeHostServices()
        let secrets = try #require(host.secrets as? InMemorySecretStore)
        secrets.setSecret("token-1", forKey: "graph-refresh-g1")
        secrets.setSecret("token-2", forKey: "graph-refresh-g2")

        ProviderFactory(host: host, securityScopedBookmarks: false).signOut(accountID: "g1")

        #expect(secrets.allSecrets() == ["graph-refresh-g2": "token-2"])
    }

    /// The half that matters most: an unbuildable Graph account is ONE dead
    /// account row. Driven through `RavenRuntime.attachStoredAccounts()`, the
    /// production path, so this observes what actually happens at launch
    /// rather than re-deriving it from the factory.
    @Test("an unconfigured Graph account does not stop other accounts attaching")
    func otherAccountsKeepWorking() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        defer { runtime.teardown() }
        try runtime.store.saveAccount(account("g1", kind: .graph))
        try runtime.store.saveAccount(account("a1", kind: .gmail))

        runtime.attachStoredAccounts()

        // Gmail attached; Graph did not. Both rows survive — the document is
        // intact and the user can still see the account that needs attention.
        #expect(runtime.syncEngines.keys.sorted() == ["a1"])
        #expect(runtime.store.accounts().map(\.id).sorted() == ["a1", "g1"])
    }

    /// And with a registration saved, the same factory builds a real Graph
    /// provider — otherwise "not configured" could be indistinguishable from
    /// "never wired up", and the test above would pass on a factory that can
    /// never build Graph at all.
    @Test("with a saved Azure registration the factory builds a Graph provider")
    func savedRegistrationBuildsAProvider() throws {
        let host = FakeHostServices()
        host.documents.setData(Data("azure-client-id".utf8),
                               forKey: ProviderFactory.azureClientIDKey)
        host.documents.setData(Data("tenant-abc".utf8),
                               forKey: ProviderFactory.azureTenantIDKey)
        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)

        #expect(factory.hasGraphCredentials)
        let provider = try factory.makeProvider(for: account("g1", kind: .graph))
        #expect(provider is GraphProvider)
        #expect(provider.accountID == "g1")
        // The id is a lookup key and lives in documents; no credential was
        // written there, and nothing at all reached the secret store.
        #expect((host.secrets as? InMemorySecretStore)?.allSecrets().isEmpty == true)
    }
}
