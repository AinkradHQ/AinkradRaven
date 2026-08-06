import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Task 16's *rules*: the well-known defaults, the boundary refusals, and the
/// classification of a failed connection.
///
/// Everything here is a pure function over values, which is why the rules were put
/// in `IMAPAccountSetup` and not in `RavenSettingsIMAPForm`. The lifecycle half —
/// what is persisted, what is purged, what the resolver then answers — is
/// `IMAPAccountLifecycleTests`.
@Suite("IMAP account setup rules")
struct IMAPAccountSetupTests {

    /// A draft that passes, so each test below can break exactly one field and the
    /// resulting refusal is attributable to that field alone.
    private func goodDraft() -> IMAPAccountSetup.Draft {
        var draft = IMAPAccountSetup.Draft()
        draft.address = "a@example.test"
        draft.imapHost = "imap.example.test"
        draft.imapPort = "993"
        draft.smtpHost = "smtp.example.test"
        draft.smtpPort = "465"
        draft.mode = .implicit
        return draft
    }

    // MARK: - Defaults per TLS mode

    @Test("each TLS mode offers its own well-known ports, and they are different")
    func portsAreOfferedPerTLSMode() {
        #expect(IMAPAccountSetup.TLSMode.implicit.defaultIMAPPort == 993)
        #expect(IMAPAccountSetup.TLSMode.implicit.defaultSMTPPort == 465)
        #expect(IMAPAccountSetup.TLSMode.startTLS.defaultIMAPPort == 143)
        #expect(IMAPAccountSetup.TLSMode.startTLS.defaultSMTPPort == 587)
        // The whole reason the defaults are per mode: one shared pair would be
        // wrong for whichever mode did not own it. Asserted rather than left to
        // the four literals above, so a future edit that collapses them fails here
        // and not only in a user's mailbox.
        #expect(IMAPAccountSetup.TLSMode.implicit.defaultIMAPPort
                != IMAPAccountSetup.TLSMode.startTLS.defaultIMAPPort)
        #expect(IMAPAccountSetup.TLSMode.implicit.defaultSMTPPort
                != IMAPAccountSetup.TLSMode.startTLS.defaultSMTPPort)
    }

    @Test("both TLS modes map to a transport mode, and STARTTLS is the explicit one")
    func bothModesShip() {
        #expect(IMAPAccountSetup.TLSMode.allCases.count == 2)
        #expect(IMAPAccountSetup.TLSMode.implicit.transport == .implicit)
        // The half Task 15b made real. Mapping it to `.implicit` would silently
        // connect a 143 port with TLS from the first byte and hang.
        #expect(IMAPAccountSetup.TLSMode.startTLS.transport == .explicit)
    }

    @Test("a known domain offers distinct IMAP and SMTP hosts; an unknown one offers none")
    func hostPresets() {
        let icloud = IMAPAccountSetup.preset(forAddress: "a@icloud.com")
        #expect(icloud?.imapHost == "imap.mail.me.com")
        #expect(icloud?.smtpHost == "smtp.mail.me.com")
        // The two hosts are genuinely different servers — a preset that derived
        // one from the other would aim submissions at the IMAP server.
        #expect(icloud?.imapHost != icloud?.smtpHost)
        #expect(IMAPAccountSetup.preset(forAddress: "A@FastMail.COM")?.imapHost
                == "imap.fastmail.com")
        // Self-hosted is the case this whole feature exists for, and it has no
        // preset. `nil`, not an error and not a guess.
        #expect(IMAPAccountSetup.preset(forAddress: "a@mail.example.test") == nil)
        #expect(IMAPAccountSetup.preset(forAddress: "no-at-sign") == nil)
    }

    // MARK: - Boundary refusals

    @Test("a port is refused unless it is a number in 1...65535")
    func portParsing() {
        #expect(IMAPAccountSetup.port(from: "993") == 993)
        #expect(IMAPAccountSetup.port(from: " 143 ") == 143)
        #expect(IMAPAccountSetup.port(from: "65535") == 65535)
        // `UInt16("0")` succeeds, so this case can only be refused deliberately.
        #expect(IMAPAccountSetup.port(from: "0") == nil)
        #expect(IMAPAccountSetup.port(from: "65536") == nil)
        #expect(IMAPAccountSetup.port(from: "99x") == nil)
        #expect(IMAPAccountSetup.port(from: "") == nil)
        #expect(IMAPAccountSetup.port(from: "-1") == nil)
    }

    @Test("an empty host and a bad port are each refused, against their own field")
    func emptyHostAndBadPortAreRefused() throws {
        var draft = goodDraft()
        draft.imapHost = "   "
        draft.smtpPort = "0"

        let failure = try #require(
            IMAPAccountSetup.validate(draft, password: "pw").failureValue)
        let fields = Set(failure.issues.map(\.field))
        #expect(fields.contains(.imapHost))
        #expect(fields.contains(.smtpPort))
        // Attribution matters as much as detection: a refusal filed against the
        // wrong field renders its message under a control that is fine.
        #expect(!fields.contains(.smtpHost))
        #expect(!fields.contains(.imapPort))
        // Every message is worded for a person, not a type name.
        for issue in failure.issues { #expect(!issue.message.isEmpty) }
    }

    @Test("all four broken fields are reported at once, not one per submit")
    func everyIssueIsReportedTogether() throws {
        var draft = IMAPAccountSetup.Draft()
        draft.imapPort = "no"
        draft.smtpPort = "70000"

        let failure = try #require(
            IMAPAccountSetup.validate(draft, password: "").failureValue)
        #expect(Set(failure.issues.map(\.field))
                == Set([.address, .imapHost, .imapPort, .smtpHost, .smtpPort, .password]))
    }

    @Test("a host with a space in it is refused")
    func hostWithSpaceIsRefused() throws {
        var draft = goodDraft()
        draft.smtpHost = "smtp .example.test"
        let failure = try #require(
            IMAPAccountSetup.validate(draft, password: "pw").failureValue)
        #expect(failure.issues.map(\.field) == [.smtpHost])
    }

    @Test("a missing password is refused at the boundary rather than attempted empty")
    func emptyPasswordIsRefused() throws {
        let failure = try #require(
            IMAPAccountSetup.validate(goodDraft(), password: "").failureValue)
        #expect(failure.issues.map(\.field) == [.password])
    }

    // MARK: - What a valid draft produces

    @Test("a valid STARTTLS draft produces explicit TLS on BOTH halves")
    func validDraftBuildsSettings() throws {
        var draft = goodDraft()
        draft.mode = .startTLS
        draft.imapPort = "143"
        draft.smtpPort = "587"

        let value = try #require(IMAPAccountSetup.validate(draft, password: "pw").successValue)
        #expect(value.address == "a@example.test")
        #expect(value.settings.host == "imap.example.test")
        #expect(value.settings.port == 143)
        #expect(value.settings.tls == .explicit)
        // The submission half is a separate server and must carry the mode too — a
        // settings value that upgraded IMAP and not SMTP would put the password on
        // a plaintext submission socket.
        #expect(value.settings.smtp?.host == "smtp.example.test")
        #expect(value.settings.smtp?.port == 587)
        #expect(value.settings.smtp?.tls == .explicit)
    }

    @Test("the username defaults to the address and an explicit one overrides it")
    func usernameDefaulting() throws {
        var draft = goodDraft()
        #expect(try #require(IMAPAccountSetup.validate(draft, password: "pw").successValue)
                .settings.username == "a@example.test")
        draft.username = "login-name"
        #expect(try #require(IMAPAccountSetup.validate(draft, password: "pw").successValue)
                .settings.username == "login-name")
    }

    @Test("the validated settings carry no trace of the password")
    func settingsNeverCarryThePassword() throws {
        let value = try #require(
            IMAPAccountSetup.validate(goodDraft(), password: "hunter2-app-pw").successValue)
        // Encoded, because that is the form the settings are persisted in — a
        // property that held only in memory would not be the one that matters.
        let encoded = String(decoding: try JSONEncoder().encode(value.settings), as: UTF8.self)
        #expect(!encoded.contains("hunter2-app-pw"))
    }

    // MARK: - Applying defaults without clobbering what was typed

    @Test("a known address fills both servers and both ports for the current mode")
    func addressFillsTheDefaults() {
        var draft = IMAPAccountSetup.Draft()
        draft.mode = .startTLS
        let filled = IMAPAccountSetup.applyingAddress("a@fastmail.com", to: draft,
                                                      hostsAreCustom: false,
                                                      portsAreCustom: false)
        #expect(filled.imapHost == "imap.fastmail.com")
        #expect(filled.smtpHost == "smtp.fastmail.com")
        #expect(filled.imapPort == "143")
        #expect(filled.smtpPort == "587")
    }

    @Test("editing the address never reverts servers or ports the user typed")
    func addressDoesNotClobberCustomFields() {
        var draft = IMAPAccountSetup.Draft()
        draft.imapHost = "mail.example.test"
        draft.smtpHost = "relay.example.test"
        draft.imapPort = "9930"
        draft.smtpPort = "9465"

        // The exact reported case: a typo fixed in an address whose domain IS
        // known, over servers the user supplied.
        let edited = IMAPAccountSetup.applyingAddress("a@fastmail.com", to: draft,
                                                      hostsAreCustom: true,
                                                      portsAreCustom: true)
        #expect(edited.address == "a@fastmail.com")
        #expect(edited.imapHost == "mail.example.test")
        #expect(edited.smtpHost == "relay.example.test")
        #expect(edited.imapPort == "9930")
        #expect(edited.smtpPort == "9465")
    }

    @Test("an unknown domain leaves the servers alone rather than clearing them")
    func unknownDomainLeavesServersAlone() {
        var draft = IMAPAccountSetup.Draft()
        draft.imapHost = "mail.example.test"
        let edited = IMAPAccountSetup.applyingAddress("a@self-hosted.test", to: draft,
                                                      hostsAreCustom: false,
                                                      portsAreCustom: false)
        #expect(edited.imapHost == "mail.example.test")
    }

    @Test("changing the TLS mode rewrites default ports but not custom ones")
    func modeChangeRespectsCustomPorts() {
        var draft = IMAPAccountSetup.Draft()
        draft.imapPort = "993"
        draft.smtpPort = "465"
        let switched = IMAPAccountSetup.applyingMode(.startTLS, to: draft,
                                                     portsAreCustom: false)
        #expect(switched.imapPort == "143")
        #expect(switched.smtpPort == "587")

        draft.imapPort = "9930"
        let kept = IMAPAccountSetup.applyingMode(.startTLS, to: draft, portsAreCustom: true)
        #expect(kept.mode == .startTLS)
        #expect(kept.imapPort == "9930")
    }

    // MARK: - Typed connection failure

    @Test("auth, TLS and host failures are three categories, not one error string")
    func classificationIsTyped() {
        // Auth: the server was reached and secured and said no.
        #expect(IMAPAccountSetup.classify(IMAPAuthError.rejected("Invalid credentials"))
                == .auth("Invalid credentials"))
        #expect(IMAPAccountSetup.classify(IMAPAuthError.plaintextLoginDisabled).isAuth)
        #expect(IMAPAccountSetup.classify(IMAPAuthError.mechanismUnavailable("XOAUTH2")).isAuth)
        // NOT auth: `IMAPAuthenticator` relabels the sign-in command's own failure
        // as `IMAPAuthError.rejected`, so a bare `commandFailed` is some OTHER
        // command — on the probe path, the `LIST "" "*"`. Reporting "check your
        // password" for a server that refused the wildcard list is the wrong
        // instruction, not merely a vague one.
        let listRefused = IMAPAccountSetup.classify(
            IMAPSessionError.commandFailed(tag: "A2", status: .no, text: "LIST not permitted"))
        #expect(listRefused == .server("LIST not permitted"))
        #expect(!listRefused.isAuth)

        // TLS: a connection existed but could not be secured.
        #expect(IMAPAccountSetup.classify(IMAPAuthError.startTLSUnadvertised).isTLS)
        #expect(IMAPAccountSetup.classify(IMAPAuthError.explicitTLSUnsupported).isTLS)
        #expect(IMAPAccountSetup.classify(MailTransportError.tlsFailed("bad cert")).isTLS)
        #expect(IMAPAccountSetup.classify(MailTransportError.tlsUpgradeUnsupported).isTLS)
        // …including when it arrives wrapped by the session.
        #expect(IMAPAccountSetup.classify(
            IMAPSessionError.transportFailure(.tlsFailed("bad cert"))).isTLS)

        // Host: nothing usable was ever reached.
        #expect(IMAPAccountSetup.classify(MailTransportError.connectionFailed("refused")).isHost)
        #expect(IMAPAccountSetup.classify(MailTransportError.timedOut).isHost)
        #expect(IMAPAccountSetup.classify(MailTransportError.closed).isHost)
    }

    @Test("each category produces its own sentence, and only the actionable ones name a field")
    func categoriesAreDistinguishableToTheUser() {
        let cases: [IMAPAccountSetup.ConnectionFailure] =
            [.auth("x"), .tls("x"), .host("x"), .server("x")]
        // A typed failure that rendered one string for all of them would be the
        // generic error this criterion replaces.
        #expect(Set(cases.map(\.message)).count == 4)
        // Three of the four send the user to a specific control; the fourth says
        // the server refused a command, which no field on this form can fix, and
        // therefore names none rather than naming a plausible wrong one.
        #expect(Set(cases.compactMap(\.field)).count == 3)
        #expect(IMAPAccountSetup.ConnectionFailure.server("x").field == nil)
        // The sign-in advice must appear for the auth case and nowhere else.
        #expect(IMAPAccountSetup.ConnectionFailure.auth("x").message.contains("password"))
        #expect(!IMAPAccountSetup.ConnectionFailure.server("x").message.contains("password"))
    }

    @Test("an unclassifiable failure is reported as a host problem, never as an auth one")
    func unknownErrorsDoNotAccuseTheCredential() {
        struct Odd: Error {}
        #expect(IMAPAccountSetup.classify(Odd()).isHost)
    }

    // MARK: - Structural: the rules and the form cannot reach a document store

    /// The tripwire an in-memory assertion cannot be. `IMAPAccountSetup` holds the
    /// password only as a function parameter and `RavenSettingsIMAPForm` only as
    /// view state; if either ever gains a document-store dependency, this fails and
    /// whoever added it has to come here and justify it. Same shape, and same
    /// comment-stripping, as `OAuthTokenClientTests.authLayerCannotReachDocuments`:
    /// these files SHOULD discuss the invariant in prose, so only code counts.
    @Test("the setup rules and the form have no document-store dependency to leak through")
    func setupCannotReachDocuments() throws {
        for path in ["Sources/RavenFeature/Provider/IMAP/IMAPAccountSetup.swift",
                     "Sources/RavenFeature/Views/RavenSettingsIMAPForm.swift"] {
            let code = try SourceTripwire.codeOnly(path)
            #expect(!code.contains("PluginDocumentStore"), "\(path)")
            #expect(!code.contains("host.documents"), "\(path)")
            #expect(!code.contains("setData"), "\(path)")
        }
    }

    /// `openSession` hardcoded `tls: .implicit` until this task, and no in-process
    /// test can observe the difference: the TLS mode is fixed when
    /// `NetworkTransport` builds its `NWParameters`, and a scripted transport has
    /// none. Rather than claim a property the suite cannot see, this asserts the
    /// only thing that is observable without a socket — that the production opener
    /// reads the user's stored choice and no longer names a constant.
    @Test("openSession takes its TLS mode from the settings, not a constant")
    func openSessionUsesTheStoredTLSMode() throws {
        let code = try SourceTripwire
            .codeOnly("Sources/RavenFeature/Provider/IMAP/IMAPProviderSession.swift")
        #expect(code.contains("NetworkTransport(endpoint: settings.endpoint)"))
        #expect(code.contains("IMAPAuthenticator(session: session, security: settings.tls)"))
        #expect(!code.contains("tls: .implicit"))
        #expect(!code.contains("security: .implicit"))
    }

    @Test("settings render the endpoint each half will actually be dialled on")
    func settingsRenderEndpoints() {
        let settings = IMAPAccountSettings(
            host: "imap.example.test", port: 143, username: "u", tls: .explicit,
            smtp: SMTPAccountSettings(host: "smtp.example.test", port: 587, tls: .explicit))
        #expect(settings.endpoint == MailTransportEndpoint(host: "imap.example.test",
                                                           port: 143, tls: .explicit))
        #expect(settings.smtpEndpoint == MailTransportEndpoint(host: "smtp.example.test",
                                                               port: 587, tls: .explicit))
    }

    /// The forward-compatibility half, which the backward one below cannot cover:
    /// `decodeIfPresent` returns nil for an ABSENT key but *throws* for an
    /// unrecognised raw value, and a throw here reads as "no settings document" to
    /// `ProviderFactory.makeIMAPProvider`, stranding the account with its row still
    /// listed and nothing explaining why it will not connect.
    @Test("a settings document naming a TLS mode this build has never heard of still loads")
    func unknownTLSModeDoesNotStrandTheAccount() throws {
        let future = Data((#"{"host":"imap.example.test","port":993,"username":"u","#
                           + #""tls":"requireTLS13","#
                           + #""smtp":{"host":"smtp.example.test","port":465,"#
                           + #""tls":"requireTLS13"}}"#).utf8)
        let settings = try JSONDecoder().decode(IMAPAccountSettings.self, from: future)

        // The account is still buildable — host, port and username all survived.
        #expect(settings.host == "imap.example.test")
        #expect(settings.port == 993)
        #expect(settings.username == "u")
        // The unreadable mode falls back to the CONSERVATIVE direction: TLS from
        // the first byte. `.explicit` would turn an unreadable value into a
        // plaintext connect, which is the one fallback that could be a downgrade.
        #expect(settings.tls == .implicit)
        // The submission block names the same unreadable mode, so it is refused
        // rather than guessed — reading keeps working, only sending is refused.
        #expect(settings.smtp == nil)
    }

    @Test("a settings document written before this task decodes as implicit TLS and no SMTP")
    func legacySettingsDecodeConservatively() throws {
        let legacy = Data(#"{"host":"imap.example.test","port":993,"username":"u"}"#.utf8)
        let settings = try JSONDecoder().decode(IMAPAccountSettings.self, from: legacy)
        #expect(settings.tls == .implicit)
        // NOT the IMAP host with a guessed port: an absent submission server is
        // refused by `send`, never invented.
        #expect(settings.smtp == nil)
        #expect(settings.smtpEndpoint == nil)
    }
}

// MARK: - Small readers, so the assertions above read as assertions

extension Result {
    var successValue: Success? { if case .success(let value) = self { return value }; return nil }
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
}

extension IMAPAccountSetup.ConnectionFailure {
    var isAuth: Bool { if case .auth = self { return true }; return false }
    var isTLS: Bool { if case .tls = self { return true }; return false }
    var isHost: Bool { if case .host = self { return true }; return false }
}

/// Reads a source file with `//` comments stripped, so prose that discusses an
/// invariant cannot satisfy — or trip — an assertion about the code.
enum SourceTripwire {
    static func codeOnly(_ repoRelativePath: String,
                         file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()      // RavenFeatureTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
        let source = try String(contentsOf: root.appending(path: repoRelativePath),
                                encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }
}
