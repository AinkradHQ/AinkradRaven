import Foundation
import Testing

@testable import RavenFeature

@Suite("IMAP credential storage", .timeLimit(.minutes(1)), .stubbedNetwork)
@MainActor
struct IMAPCredentialStorageTests {

    @Test("the app password comes from host.secrets and nothing else is stored beside it")
    func appPasswordFromSecrets() throws {
        let secrets = InMemorySecretStore()
        #expect(
            IMAPAppPasswordStore.credential(
                accountID: Fixture.address, username: Fixture.address, secrets: secrets) == nil)

        IMAPAppPasswordStore.store(Fixture.password, accountID: Fixture.address, secrets: secrets)
        let credential = try #require(
            IMAPAppPasswordStore.credential(
                accountID: Fixture.address, username: Fixture.address, secrets: secrets))
        guard case .appPassword(let username, let password) = credential else {
            Issue.record("expected an app-password credential")
            return
        }
        #expect(username == Fixture.address)
        #expect(password == Fixture.password)

        // EXHAUSTIVE: one key, the password, and nothing that got cached beside it.
        #expect(secrets.allSecrets() == ["imap-app-password-a@example.test": Fixture.password])

        IMAPAppPasswordStore.clear(accountID: Fixture.address, secrets: secrets)
        #expect(secrets.allSecrets().isEmpty)
    }

    @Test("an empty stored password is treated as absent rather than attempted")
    func emptyPasswordIsAbsent() {
        let secrets = InMemorySecretStore()
        IMAPAppPasswordStore.store("", accountID: Fixture.address, secrets: secrets)
        #expect(
            IMAPAppPasswordStore.credential(
                accountID: Fixture.address, username: Fixture.address, secrets: secrets) == nil)
    }

    @Test("the refresh token persists in host.secrets and the access token only in memory")
    func oauthTokenSplit() async throws {
        let secrets = InMemorySecretStore()
        StubURLProtocol.handler = { _ in
            (
                200, [:],
                Data(
                    """
                    {"access_token":"\(Fixture.accessToken)","expires_in":3599}
                    """.utf8)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let client = OAuthTokenClient(
            configuration: OAuthConfiguration(
                authorizationEndpoint: URL(string: "https://example.test/authorize")!,
                tokenEndpoint: URL(string: "https://example.test/token")!,
                clientID: "cid", clientSecret: nil, scopes: ["imap"]),
            session: StubURLProtocol.makeSession())
        let source = IMAPOAuthCredentialSource(client: client, secrets: secrets)
        source.storeRefreshToken(Fixture.refreshToken, accountID: Fixture.address)

        let credential = try await source.credential(
            accountID: Fixture.address, username: Fixture.address)
        guard case .xoauth2(_, let accessToken) = credential else {
            Issue.record("expected an XOAUTH2 credential")
            return
        }
        #expect(accessToken == Fixture.accessToken)
        // Access token: memory only.
        #expect(source.accessTokens[Fixture.address]?.token == Fixture.accessToken)
        // Refresh token in the Keychain-backed store, and EXHAUSTIVELY nothing
        // else — in particular the access token was not cached beside it.
        #expect(secrets.allSecrets() == ["imap-refresh-a@example.test": Fixture.refreshToken])

        source.signOut(accountID: Fixture.address)
        #expect(secrets.allSecrets().isEmpty)
        #expect(source.accessTokens[Fixture.address] == nil)
    }

    @Test("no refresh token means notAuthenticated, not an empty bearer attempt")
    func missingRefreshToken() async throws {
        let client = OAuthTokenClient(
            configuration: OAuthConfiguration(
                authorizationEndpoint: URL(string: "https://example.test/authorize")!,
                tokenEndpoint: URL(string: "https://example.test/token")!,
                clientID: "cid", clientSecret: nil, scopes: ["imap"]),
            session: StubURLProtocol.makeSession())
        let source = IMAPOAuthCredentialSource(client: client, secrets: InMemorySecretStore())
        await #expect(throws: MailError.notAuthenticated(accountID: Fixture.address)) {
            _ = try await source.credential(
                accountID: Fixture.address, username: Fixture.address)
        }
    }
}
