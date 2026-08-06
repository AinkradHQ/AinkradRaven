import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Task 1 of M6: the account kind is open, and `ProviderFactory` is the only
/// place a `MailProvider` is built. Each test here pins one property the
/// single-kind, inline-construction shape could not have had.
@Suite("ProviderFactory")
@MainActor struct ProviderFactoryTests {

    private func account(_ id: String, kind: MailAccount.ProviderKind) -> MailAccount {
        MailAccount(id: id, provider: kind, address: "\(id)@example.test",
                    displayName: id, state: .ready)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderFactoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A factory whose Gmail client comes from manually-saved credentials, so
    /// these tests do not depend on whether `BakedOAuthCredentials` was
    /// generated in this build.
    private func factoryWithGmailCredentials(host: FakeHostServices) -> ProviderFactory {
        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)
        factory.saveGmailCredentials(clientID: "client-id", clientSecret: "client-secret")
        return factory
    }

    // MARK: The stored kind

    @Test("gmail decodes from an existing accounts document unchanged")
    func legacyGmailDecodes() throws {
        // Byte-for-byte the shape M0 wrote: `provider` is the bare string
        // "gmail" and there is no kind discriminator around it.
        let json = """
        [{"id":"a1","provider":"gmail","address":"a@example.test","displayName":"A",\
        "state":"ready","signature":""}]
        """
        let accounts = try JSONDecoder().decode([MailAccount].self, from: Data(json.utf8))
        #expect(accounts.count == 1)
        #expect(accounts[0].provider == .gmail)
        #expect(accounts[0].id == "a1")
    }

    @Test("every kind round-trips through JSON as a bare string")
    func kindsRoundTrip() throws {
        let kinds: [MailAccount.ProviderKind] = [.gmail, .imap, .graph, .appleMail,
                                                .unsupported("carrierpigeon")]
        for kind in kinds {
            let data = try JSONEncoder().encode(account("a1", kind: kind))
            let decoded = try JSONDecoder().decode(MailAccount.self, from: data)
            #expect(decoded.provider == kind)
            // Encoded as the bare identifier string, not a keyed container —
            // that is what keeps the stored document format unchanged.
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["provider"] as? String == kind.identifier)
        }
        #expect(MailAccount.ProviderKind.gmail.identifier == "gmail")
    }

    @Test("an unknown kind on one row leaves its sibling accounts loadable")
    func unknownKindDoesNotStrandSiblings() throws {
        let json = """
        [{"id":"a1","provider":"gmail","address":"a@example.test","displayName":"A",\
        "state":"ready","signature":""},\
        {"id":"a2","provider":"quantumpost","address":"b@example.test","displayName":"B",\
        "state":"ready","signature":""},\
        {"id":"a3","provider":"gmail","address":"c@example.test","displayName":"C",\
        "state":"ready","signature":""}]
        """
        let documents = InMemoryDocumentStore()
        documents.setData(Data(json.utf8), forKey: DocumentKeys.accounts)
        let store = DocumentMailStore(documents: documents)
        // The whole array survives: the store reads `accounts` as ONE document,
        // so a strict per-row decode failure would have returned [] and
        // signed the user out of every mailbox.
        let accounts = store.accounts()
        #expect(accounts.map(\.id) == ["a1", "a2", "a3"])
        #expect(accounts[1].provider == .unsupported("quantumpost"))
        #expect(store.lastCorruptDocumentKey == nil)
    }

    @Test("re-saving an unknown kind preserves its original string")
    func unknownKindRoundTripsUnchanged() throws {
        let documents = InMemoryDocumentStore()
        let store = DocumentMailStore(documents: documents)
        try store.saveAccount(account("a1", kind: .unsupported("quantumpost")))
        let data = try #require(documents.data(forKey: DocumentKeys.accounts))
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(raw.contains("\"quantumpost\""))
        #expect(store.accounts()[0].provider == .unsupported("quantumpost"))
    }

    // MARK: Kind → conformer

    @Test("gmail maps to GmailProvider")
    func gmailMapsToGmailProvider() throws {
        let factory = factoryWithGmailCredentials(host: FakeHostServices())
        let provider = try factory.makeProvider(for: account("a1", kind: .gmail))
        #expect(provider is GmailProvider)
        #expect(provider.accountID == "a1")
        #expect(provider.capabilities == .readWrite)
    }

    /// The "no Gmail client at all" branch (`MailError.notAuthenticated` keyed
    /// to the account id) is deliberately NOT asserted here: on a developer
    /// machine `BakedOAuthCredentials` is generated from
    /// `Config/oauth-client.json`, so `ProviderFactory` legitimately always
    /// finds a client and the branch is unreachable without injecting a fake
    /// credential source — which would mean widening the credential path this
    /// task exists to narrow.

    @Test("appleMail maps to the read-only AppleMailProvider")
    func appleMailMapsToAppleMailProvider() throws {
        let host = FakeHostServices()
        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)
        let dir = try makeTempDir()
        factory.saveAppleMailDirectory(try MailDirectoryBookmark.create(for: dir,
                                                                       securityScoped: false),
                                       accountID: "am1")
        let provider = try factory.makeProvider(for: account("am1", kind: .appleMail))
        #expect(provider is AppleMailProvider)
        #expect(provider.capabilities == .readOnly)
    }

    @Test("appleMail with no saved directory refuses by account id")
    func appleMailWithoutDirectory() throws {
        let factory = ProviderFactory(host: FakeHostServices(), securityScopedBookmarks: false)
        #expect(throws: MailError.unsupportedProvider(kind: "appleMail", accountID: "am1")) {
            _ = try factory.makeProvider(for: account("am1", kind: .appleMail))
        }
    }

    @Test("kinds whose backend has not landed refuse by name, per account")
    func pendingKindsRefuse() throws {
        let factory = factoryWithGmailCredentials(host: FakeHostServices())
        // `.graph` left this list in Task 19: its backend HAS landed, so an
        // unbuildable Graph account is now "no Azure registration in this
        // build" (`notAuthenticated`), not "no such backend". That state has
        // its own test in `GraphAccountStateTests.swift` (suite "Graph not
        // configured") — named by FILE, so this reference is greppable.
        for kind in [MailAccount.ProviderKind.imap, .unsupported("quantumpost")] {
            #expect(throws: MailError.unsupportedProvider(kind: kind.identifier,
                                                          accountID: "a1")) {
                _ = try factory.makeProvider(for: account("a1", kind: kind))
            }
        }
    }

    @Test("no interactive sign-in exists for a kind that has no flow yet")
    func authorizeRefusesUnsupportedKinds() async throws {
        let factory = factoryWithGmailCredentials(host: FakeHostServices())
        // `.graph` has a flow as of Task 19 — see `GraphAccountStateTests.swift`
        // (suite "Graph not configured") for what it answers when no Azure
        // registration is baked in.
        for kind in [MailAccount.ProviderKind.imap, .appleMail] {
            await #expect(throws: MailError.unsupportedProvider(kind: kind.identifier,
                                                               accountID: "")) {
                _ = try await factory.authorize(kind: kind)
            }
        }
    }

    // MARK: The read-only path, in production shape

    /// The first non-test exercise of `MailProviderCapabilities`/
    /// `writableProvider`: an `.appleMail` account attached exactly the way
    /// `RavenRuntime.attachStoredAccounts()` attaches one — factory-built
    /// provider, real `MailProviderRouter`, real `SyncEngine` — and a send
    /// routed to it refused at the router. Only the bookmark's security-scope
    /// option differs from production (see `ProviderFactory.init`).
    @Test("a send on an appleMail account is refused with readOnlyAccount")
    func appleMailSendIsRefused() async throws {
        let host = FakeHostServices()
        let runtime = RavenRuntime(host: host)
        runtime.teardown()
        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)
        let dir = try makeTempDir()
        factory.saveAppleMailDirectory(try MailDirectoryBookmark.create(for: dir,
                                                                       securityScoped: false),
                                       accountID: "am1")
        let stored = account("am1", kind: .appleMail)
        try runtime.store.saveAccount(stored)
        runtime.attach(provider: try factory.makeProvider(for: stored), accountID: "am1")

        #expect(runtime.isReadOnly(accountID: "am1"))
        #expect(throws: MailError.readOnlyAccount("am1")) {
            _ = try runtime.providers.writableProvider(for: "am1")
        }
        // And the read side still works: attaching a read-only backend gives a
        // real engine, so the account is not merely inert.
        #expect(runtime.providers.provider(for: "am1") != nil)
        #expect(runtime.syncEngines["am1"] != nil)
    }

    // MARK: Sign-out

    @Test("signing out one account drops only its own factory state")
    func signOutIsAccountScoped() throws {
        let host = FakeHostServices()
        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)
        let dir = try makeTempDir()
        let bookmark = try MailDirectoryBookmark.create(for: dir, securityScoped: false)
        factory.saveAppleMailDirectory(bookmark, accountID: "am1")
        factory.saveAppleMailDirectory(bookmark, accountID: "am2")
        factory.signOut(accountID: "am1")
        #expect(host.documents.data(forKey: DocumentKeys.appleMailDirectory(accountID: "am1")) == nil)
        #expect(host.documents.data(forKey: DocumentKeys.appleMailDirectory(accountID: "am2")) != nil)
    }

    // MARK: Security-scoped access is balanced

    /// `startAccessing` is only ever balanced by `stopAccessing` with the SAME
    /// URL, so a factory that starts access without retaining the URL can never
    /// stop it — the grant to the user's Mail folder would then survive
    /// sign-out and live until the process exits. These assert the bookkeeping
    /// that makes stopping possible; the sandbox consequence itself is not
    /// observable here, because tests run unsandboxed with
    /// `securityScopedBookmarks: false`.
    @Test("building an Apple Mail provider retains the accessed directory so it can be released")
    func appleMailAccessIsRetained() throws {
        let host = FakeHostServices()
        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)
        let dir = try makeTempDir()
        factory.saveAppleMailDirectory(try MailDirectoryBookmark.create(for: dir,
                                                                       securityScoped: false),
                                       accountID: "am1")
        _ = try factory.makeProvider(for: account("am1", kind: .appleMail))
        #expect(factory.accessedDirectories["am1"] != nil)

        factory.signOut(accountID: "am1")
        #expect(factory.accessedDirectories["am1"] == nil)
    }

    /// `attachStoredAccounts()` re-runs `makeProvider` for EVERY account each
    /// time credentials are saved, so this path is walked repeatedly in normal
    /// use. Each pass must not add another unbalanced start for the same URL.
    @Test("rebuilding the same Apple Mail account does not stack access grants")
    func appleMailAccessIsIdempotent() throws {
        let host = FakeHostServices()
        let factory = ProviderFactory(host: host, securityScopedBookmarks: false)
        let dir = try makeTempDir()
        factory.saveAppleMailDirectory(try MailDirectoryBookmark.create(for: dir,
                                                                       securityScoped: false),
                                       accountID: "am1")
        let stored = account("am1", kind: .appleMail)
        for _ in 0..<3 { _ = try factory.makeProvider(for: stored) }

        // One entry, not three: the map is keyed by account, so a re-attach
        // replaces rather than accumulates.
        #expect(factory.accessedDirectories.count == 1)
        let retained = try #require(factory.accessedDirectories["am1"])
        #expect(retained.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
    }

    // MARK: Every RawRepresentable field on the account row is lenient

    /// The `ProviderKind` rewrite was justified by "one bad row must not strand
    /// every mailbox", and `state` sits in the same array on the same row — so a
    /// strict decode there reintroduces the identical failure one field over.
    @Test("an unknown state does not strand the accounts document")
    func unknownStateDoesNotStrandSiblings() throws {
        let host = FakeHostServices()
        let store = DocumentMailStore(documents: host.documents)
        let json = """
        [{"id":"a1","provider":"gmail","address":"a@example.test","displayName":"A",\
        "state":"ready","signature":""},\
        {"id":"a2","provider":"gmail","address":"b@example.test","displayName":"B",\
        "state":"paused","signature":""}]
        """
        host.documents.setData(Data(json.utf8), forKey: DocumentKeys.accounts)

        let accounts = store.accounts()
        #expect(accounts.map(\.id) == ["a1", "a2"])
        #expect(accounts[0].state == .ready)
        // Unknown → needsAuth: it asks the user to look rather than claiming a
        // sync succeeded, and `SyncEngine` overwrites it on the next pass.
        #expect(accounts[1].state == .needsAuth)
    }
}
