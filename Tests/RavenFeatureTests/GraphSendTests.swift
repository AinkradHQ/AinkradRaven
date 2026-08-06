import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// `GraphMutations.send`: the two-request shape, the recipient split, at-most-once,
/// and the router that gets a send here rather than to Gmail.
///
/// **Verified against recorded fixtures and `StubURLProtocol` only.** There is no
/// Azure app registration, so nothing here has met a live Graph endpoint; live
/// verification is Task 24's.
@Suite("Graph send")
@MainActor
struct GraphSendTests {

    private static func message(bcc: [MailAddress] = [MailAddress(email: "d@example.test")])
        -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "b@example.test", name: "Person B")],
                        cc: [MailAddress(email: "c@example.test")],
                        bcc: bcc,
                        subject: "Subject 1",
                        bodyText: "Body 1",
                        accountID: "a1")
    }

    /// The stub: the draft-creation fixture for `POST /messages`, a bodiless `202`
    /// for the commit, and nothing else.
    private func arm() throws -> RecordedRequests {
        let recorded = RecordedRequests()
        let created = try graphFixture("graph-created-draft")
        StubURLProtocol.handler = { request in
            recorded.record(request)
            if request.url?.absoluteString.hasSuffix("/send") == true {
                // Graph's real answer: 202 Accepted, zero bytes.
                return (202, [:], Data())
            }
            return (201, [:], created)
        }
        return recorded
    }

    private func teardown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.transportFailure = nil
    }

    // MARK: The fixture the id assertions rest on

    /// The created-draft fixture carries THREE plausible id-shaped fields, and only
    /// one of them is the message id. Pinned first so the assertion below —
    /// "`send` returns `AAMkDRAFT-1`" — is known to be distinguishing rather than
    /// coincidentally right.
    @Test("the created-draft fixture holds three distinct id-shaped fields")
    func createdDraftFixtureShape() throws {
        let data = try graphFixture("graph-created-draft")
        let decoded = try JSONSerialization.jsonObject(with: data)
        let object = try #require(decoded as? [String: Any])
        #expect(object.count == 5)
        #expect(object["id"] as? String == "AAMkDRAFT-1")
        #expect(object["conversationId"] as? String == "AAQkCONV-9")
        #expect(object["internetMessageId"] as? String == "<mime-7@example.test>")
    }

    // MARK: The send shape

    /// Two requests, in this order, and the returned id is the one Graph minted for
    /// the draft.
    ///
    /// The one-shot `POST /me/sendMail` shape — JSON or base64 MIME — was rejected
    /// because it answers `202` with an EMPTY body: there is no id in it, so a
    /// provider on that shape must fabricate the value `MailProvider.send` returns.
    /// See `GraphSendPayload` for the full comparison.
    @Test("send creates the draft, records its id, then commits it")
    func sendIsCreateThenCommit() async throws {
        defer { teardown() }
        let recorded = try arm()

        let id = try await graphBounded("send") {
            try await makeGraphProvider().send(Self.message())
        }
        #expect(id == "AAMkDRAFT-1")

        let entries = recorded.all
        #expect(entries.count == 2)
        #expect(entries.map { "\($0.method) \($0.path)" }
                == ["POST messages", "POST messages/AAMkDRAFT-1/send"])
        // The commit is addressed by the id from the response, so it also pins that
        // the id was READ rather than guessed from the request.
        #expect(entries[1].body.isEmpty)
    }

    /// A response with no usable id is a typed failure, never a fabricated id. This
    /// is the property the read-only period was built around and flipping
    /// `capabilities` to `.readWrite` must not weaken: a send is reported only on
    /// evidence from the server.
    @Test("a draft response with no id fails instead of inventing one")
    func missingIDIsAFailureNotAFabrication() async throws {
        let recorded = RecordedRequests()
        StubURLProtocol.handler = { request in
            recorded.record(request)
            return (201, [:], Data(#"{"conversationId":"AAQkCONV-9"}"#.utf8))
        }
        defer { teardown() }

        await #expect(throws: MailError.decodingFailed("graph draft id")) {
            try await graphBounded("send(no id)") {
                try await makeGraphProvider().send(Self.message())
            }
        }
        // And crucially: the commit was never issued, so nothing was sent under a
        // guessed id. The `conversationId` present in the body is the plausible
        // wrong answer this pins against.
        #expect(recorded.all.map(\.path) == ["messages"])
    }

    // MARK: Bcc

    /// **Bcc is a delivery instruction on the payload, disclosed to nobody.**
    ///
    /// Graph is a third shape beside the two existing policies, which are
    /// deliberately opposite: Gmail's `messages/send` derives the envelope from the
    /// transmitted headers, so `RFC822Builder(includeBccHeader: true)` is required
    /// or the blind recipient is silently dropped; SMTP carries recipients in
    /// `RCPT TO`, so a transmitted `Bcc:` header would disclose the list — which is
    /// why `includeBccHeader` has no default. Graph is the SMTP case in JSON: a
    /// `bccRecipients` array sibling to `toRecipients`/`ccRecipients`, from which
    /// Graph composes each recipient's copy itself. `RFC822Builder` is not on this
    /// path at all.
    ///
    /// Asserted three ways, because the split alone is not enough: the arrays are
    /// exact (so a merged Bcc fails), the blind address occurs EXACTLY ONCE in the
    /// entire serialized payload (so it cannot also be hiding in the body or a
    /// header collection), and there is no header-bearing key at all.
    @Test("bcc recipients are set on the payload and appear nowhere else in it")
    func bccIsADeliveryInstructionAndNotDisclosed() async throws {
        defer { teardown() }
        let recorded = try arm()

        _ = try await graphBounded("send") {
            try await makeGraphProvider().send(Self.message())
        }
        let entries = recorded.all
        #expect(entries.count == 2)
        let draft = entries[0]
        let json = try #require(draft.json)

        func addresses(_ key: String) throws -> [String] {
            let list = try #require(json[key] as? [[String: Any]], "\(key) is missing")
            var found: [String] = []
            for recipient in list {
                let email = try #require(recipient["emailAddress"] as? [String: Any])
                found.append(try #require(email["address"] as? String))
            }
            return found
        }
        let to = try addresses("toRecipients")
        let cc = try addresses("ccRecipients")
        let blind = try addresses("bccRecipients")
        #expect(to == ["b@example.test"])
        #expect(cc == ["c@example.test"])
        #expect(blind == ["d@example.test"])

        // Exactly once in the whole body. A merged Bcc, a Bcc echoed into a
        // header collection, or a Bcc pasted into the rendered HTML all break this
        // where the array assertions above would still pass.
        let occurrences = draft.body.components(separatedBy: "d@example.test").count - 1
        #expect(occurrences == 1, "the blind address appears \(occurrences) times in the payload")
        // No transmitted-header channel is used at all, so there is nowhere for a
        // `Bcc:` header to be added later without this failing.
        #expect(json["internetMessageHeaders"] == nil)
        #expect(draft.body.contains("Bcc") == false)

        // The display name the user typed is carried; one they did not type is not
        // invented from the address.
        let firstTo = try #require((json["toRecipients"] as? [[String: Any]])?.first)
        #expect((firstTo["emailAddress"] as? [String: Any])?["name"] as? String == "Person B")
        let firstBcc = try #require((json["bccRecipients"] as? [[String: Any]])?.first)
        #expect((firstBcc["emailAddress"] as? [String: Any])?["name"] == nil)
    }

    /// The contrast that keeps the assertion above honest: with no blind recipient
    /// the array is present and EMPTY, rather than the address having leaked into
    /// `toRecipients`. Without this, "bcc appears once" could be satisfied by a
    /// payload that never had a bcc at all.
    @Test("with no blind recipient the array is empty, not merged away")
    func emptyBccIsStillItsOwnArray() async throws {
        defer { teardown() }
        let recorded = try arm()

        _ = try await graphBounded("send(no bcc)") {
            try await makeGraphProvider().send(Self.message(bcc: []))
        }
        #expect(recorded.all.count == 2)
        let json = try #require(recorded.all[0].json)
        #expect((json["bccRecipients"] as? [[String: Any]])?.isEmpty == true)
        #expect((json["toRecipients"] as? [[String: Any]])?.count == 1)
    }

    // MARK: At-most-once

    /// **A failure of the COMMIT is possibly-sent, and is never auto-retried.**
    ///
    /// Driven through a real `Outbox` with a real `GraphProvider`, so the classification
    /// is the one that actually happens inside the drain rather than a fake error
    /// handed to the outbox.
    ///
    /// The trap this deliberately avoids is Task 15's: its first version retried
    /// against an *exhausted* transport, so a retry died at the door and an unchanged
    /// `sent` proved nothing. Here the stub is **re-armed to a fully working script**
    /// before the second drain — a Graph that would gladly accept another draft and
    /// another commit — and the observation is that it received nothing. That is a
    /// falsifiable wire assertion: if the outbox retried, the recorder would grow.
    @Test("a commit that leaves without a verdict is held for review and never retried")
    func outboxDoesNotRetryPossiblySent() async throws {
        let recorded = RecordedRequests()
        let created = try graphFixture("graph-created-draft")
        // The draft is created successfully; the COMMIT's connection dies after the
        // request left. That asymmetry is the whole point — step 1 failing means
        // nothing was sent and is retryable, step 2 failing means nobody knows.
        StubURLProtocol.transportFailure = { request in
            guard request.url?.absoluteString.hasSuffix("/send") == true else { return nil }
            recorded.record(request)
            return URLError(.networkConnectionLost)
        }
        StubURLProtocol.handler = { request in
            recorded.record(request)
            return (201, [:], created)
        }
        defer { teardown() }

        let provider = makeGraphProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider,
                            accountID: "a1")
        let id = try outbox.enqueue(.send(Self.message()), accountID: "a1")
        try await graphBounded("drain 1") { await outbox.drain() }

        #expect(outbox.outcome(for: id) == .needsReview)
        #expect(outbox.needsReview().map(\.id) == [id])
        #expect(outbox.pending().isEmpty, "a possibly-sent entry must not be eligible again")
        // Attempts stay at zero: this is not a failure that earns a retry, it is an
        // outcome nobody knows.
        #expect(outbox.needsReview().first?.attempts == 0)
        // Both requests really did go out — this is the post-commit branch, not an
        // earlier failure wearing the same error.
        #expect(recorded.all.map(\.path) == ["messages", "messages/AAMkDRAFT-1/send"])

        // Re-arm to a Graph that would happily take the message again.
        StubURLProtocol.transportFailure = nil
        StubURLProtocol.handler = { request in
            recorded.record(request)
            if request.url?.absoluteString.hasSuffix("/send") == true {
                return (202, [:], Data())
            }
            return (201, [:], created)
        }
        try await graphBounded("drain 2") { await outbox.drain() }

        #expect(recorded.count == 2, "a second drain retransmitted a possibly-sent message")
        #expect(outbox.outcome(for: id) == .needsReview)
        outbox.teardownWake()
    }

    /// **A non-2xx on the commit is possibly-sent too, and this is what asserts the
    /// status guard in `writeExpectingNoContent`.**
    ///
    /// That guard is the only status check on the write path that does NOT come from
    /// `GraphProvider.perform` — the helper exists precisely because `perform`
    /// decodes unconditionally and would turn every successful `202`-with-no-body
    /// into `decodingFailed`. Deleting the guard leaves `send` returning the draft
    /// id after a `403`/`429`/`500`, and `Outbox` recording `.sent` for a message
    /// the server refused: success INFERRED from "the transport did not throw",
    /// which is the one inversion this branch's send path forbids.
    ///
    /// ## Why every non-2xx is unknown rather than a 4xx being retryable
    ///
    /// A retryable 4xx is tempting — a `400` surely means the server did nothing —
    /// but it is wrong *for this shape*, and the reason is the retry, not the
    /// status. `Outbox.drain` retries by calling `send` again, which creates a
    /// **second draft** and commits that; the first draft still exists server-side.
    /// So if the commit had in fact landed (a `429` after the message was queued, a
    /// `500` from a gateway in front of a service that accepted it), a retry
    /// delivers the mail twice. The statuses where duplication is most likely —
    /// `429` and `5xx` — are exactly the ones a status-based rule would classify as
    /// retryable, so the rule buys nothing and risks the one failure the send path
    /// exists to prevent. `SMTPSession.finishData` takes the same direction after
    /// `DATA` for the same reason.
    ///
    /// Parameterised over four statuses because "the guard is present" and "the
    /// guard covers 4xx as well as 5xx" are different claims.
    @Test("a refused commit is reported as possibly sent, never as sent",
          arguments: [400, 403, 429, 500])
    func aRefusedCommitIsPossiblySent(status: Int) async throws {
        let recorded = RecordedRequests()
        let created = try graphFixture("graph-created-draft")
        StubURLProtocol.handler = { request in
            recorded.record(request)
            if request.url?.absoluteString.hasSuffix("/send") == true {
                // A bodiless refusal, which is what makes this a test of the STATUS
                // check: a handler returning JSON here would also be caught by a
                // decode, so the failure could not be attributed to the guard.
                return (status, [:], Data())
            }
            return (201, [:], created)
        }
        defer { teardown() }

        await #expect(throws: MailError.sendOutcomeUnknown(
            message: "the send request for Graph draft AAMkDRAFT-1 left without a verdict")) {
            try await graphBounded("send(commit \(status))") {
                try await makeGraphProvider().send(Self.message())
            }
        }
        // Both requests went out, so this is the post-commit branch.
        #expect(recorded.all.map(\.path) == ["messages", "messages/AAMkDRAFT-1/send"])
    }

    /// The same refusal seen from the outside: through `SendAttempt`, so the two
    /// things a user can actually observe are pinned — the outcome is
    /// `.needsReview` (held, never auto-retried) and **the draft survives**.
    ///
    /// `SendAttempt` removes a draft if and only if the outcome is `.sent`, so a
    /// missing status guard would delete the user's draft for a message the server
    /// refused — the irrecoverable half of this bug.
    @Test("a refused commit holds the entry for review and keeps the draft")
    func aRefusedCommitKeepsTheDraft() async throws {
        let recorded = RecordedRequests()
        let created = try graphFixture("graph-created-draft")
        StubURLProtocol.handler = { request in
            recorded.record(request)
            if request.url?.absoluteString.hasSuffix("/send") == true {
                return (403, [:], Data())
            }
            return (201, [:], created)
        }
        defer { teardown() }

        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: makeGraphProvider(),
                            accountID: "a1")
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(Self.message())
        defer { DraftBox.shared.remove(draftID) }

        let result = try await graphBounded("SendAttempt") {
            try await SendAttempt.send(Self.message(), draftID: draftID, outbox: outbox,
                                       store: store) { await outbox.drain() }
        }
        #expect(result.isSent == false)
        #expect(result.outcome == .needsReview)
        #expect(DraftBox.shared.draft(draftID) != nil,
                "a refused commit must not destroy the user's draft")
        #expect(outbox.needsReview().map(\.id) == [result.entryID])
        #expect(outbox.pending().isEmpty)
        #expect(recorded.all.map(\.path) == ["messages", "messages/AAMkDRAFT-1/send"])
        outbox.teardownWake()
    }

    /// The contrast that keeps the test above honest: a failure of the **draft
    /// creation** means nothing was sent, so it IS retried and it does succeed.
    /// Without this, "held for review" could be the outbox refusing to retry
    /// anything a Graph provider ever queued.
    @Test("a failure before the commit is an ordinary retryable failure")
    func aFailedDraftCreationIsRetried() async throws {
        let recorded = RecordedRequests()
        let created = try graphFixture("graph-created-draft")
        let failFirst = OneShotFlag()
        StubURLProtocol.handler = { request in
            recorded.record(request)
            if request.url?.absoluteString.hasSuffix("/send") == true {
                return (202, [:], Data())
            }
            if failFirst.take() { return (503, [:], Data(#"{"error":{}}"#.utf8)) }
            return (201, [:], created)
        }
        defer { teardown() }

        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: makeGraphProvider(),
                            accountID: "a1")
        let id = try outbox.enqueue(.send(Self.message()), accountID: "a1")
        try await graphBounded("drain 1") { await outbox.drain() }
        #expect(outbox.outcome(for: id) == .queued(inFlight: false))
        #expect(outbox.pending().map(\.id) == [id])

        try await graphBounded("drain 2") { await outbox.drain() }
        #expect(outbox.outcome(for: id) == .sent)
        #expect(recorded.all.map(\.path)
                == ["messages", "messages", "messages/AAMkDRAFT-1/send"])
        outbox.teardownWake()
    }

    // MARK: Routing

    /// `capabilities` is `.readWrite`, and `MailProviderRouter.writableProvider`
    /// routes an account-scoped send to the Graph provider — not to the Gmail one
    /// attached beside it.
    ///
    /// Asserted on the WIRE as well as on identity: both providers run through
    /// `StubURLProtocol`, so if the send had gone to Gmail the recorded host would
    /// be `gmail.googleapis.com`. Identity alone would not catch a router that
    /// returned the right object to a caller that then used the wrong one.
    @Test("a send scoped to a Graph account routes to Graph and not to Gmail")
    func writableProviderRoutesToGraph() async throws {
        defer { teardown() }
        let recorded = try arm()

        let secrets = InMemorySecretStore()
        secrets.setSecret("refresh-token", forKey: "refresh-g1")
        let gmail = GmailProvider(
            accountID: "g1",
            auth: GmailAuth(secrets: secrets, clientID: "cid", clientSecret: "csecret") { _ in
                ("gmail-access-token", 3600)
            },
            session: StubURLProtocol.makeSession())
        let graph = makeGraphProvider(accountID: "x1")

        let router = MailProviderRouter()
        router.attach(gmail, accountID: "g1")
        router.attach(graph, accountID: "x1")

        #expect(graph.capabilities == .readWrite)
        let routed = try router.writableProvider(for: "x1")
        #expect(routed.accountID == "x1")
        #expect(routed is GraphProvider)
        // The Gmail account still routes to Gmail — the table was not clobbered.
        let gmailRouted = try router.writableProvider(for: "g1")
        #expect(gmailRouted is GmailProvider)

        let id = try await graphBounded("routed send") {
            try await routed.send(Self.message().attributed(to: "x1"))
        }
        #expect(id == "AAMkDRAFT-1")
        let hosts = Set(recorded.all.compactMap { URL(string: $0.url)?.host })
        #expect(hosts == ["graph.microsoft.com"])
        #expect(recorded.all.count == 2)
    }
}

/// A flag that is true exactly once, for a stub that must fail one request and then
/// behave. `@unchecked Sendable` for the same reason `SeenRequests` is: it is read
/// from inside a `URLProtocol` handler, off the main actor.
final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
