import Testing
import Foundation
@testable import RavenFeature

/// Covers two of Compose's remaining M0 requirements that don't fit neatly
/// under `RecipientChipTests`/`RecipientSuggestionsTests`/`SendAttemptTests`:
/// drafts created through the MCP `create_draft` path being visible via
/// `DraftBox.all()`, and a failed send leaving the chip-derived recipients
/// (not just subject/body) untouched.
@Suite("Compose draft listing and send-failure preservation")
@MainActor struct ComposeDraftAndSendPreservationTests {
    @Test("a draft saved through the DraftBox path (as create_draft via MCP would) is visible via DraftBox.all()")
    func draftFromMCPPathIsListed() throws {
        let message = OutgoingMessage(to: [MailAddress(email: "bea@x.com", name: "Bea Smith")],
                                      subject: "Q3 numbers", bodyText: "See attached.")
        // This is exactly what `RavenMCPOperations`'s create_draft tool does:
        // save into the shared box with no id, letting DraftBox mint one.
        let id = try DraftBox.shared.save(message)

        let listed = DraftBox.shared.all()

        #expect(listed.contains { $0.id == id })
        #expect(listed.first { $0.id == id }?.message.subject == "Q3 numbers")
        #expect(listed.first { $0.id == id }?.message.to.first?.email == "bea@x.com")
        DraftBox.shared.remove(id)
    }

    @Test("a failed send leaves chip-derived recipients, subject, and body untouched")
    func failedSendPreservesChipDerivedRecipients() async throws {
        // Mirrors ComposeSurface.message(): chips -> valid addresses -> OutgoingMessage.
        let chips = [RecipientChip(raw: "garbage"), RecipientChip(raw: "bea@x.com")]
        let recipients = ComposeValidation.validAddresses(chips)
        let outgoing = OutgoingMessage(to: recipients, subject: "Hello", bodyText: "Body text")

        let provider = FakeMailProvider()
        provider.failures["send"] = [MailError.notAuthenticated(accountID: "a1")]
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider, maxAttempts: 1)
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let draftID = try DraftBox.shared.save(outgoing)

        let result = try await SendAttempt.send(outgoing, draftID: draftID, outbox: outbox,
                                                store: store, drain: outbox.drain)

        #expect(result.isSent == false)
        // Nothing about the chip-derived message was mutated by the failed
        // attempt — the same recipients, subject, and body the composer had
        // are still exactly what the (kept) draft holds.
        let kept = try #require(DraftBox.shared.draft(draftID))
        #expect(kept.to.map(\.email) == ["bea@x.com"])
        #expect(kept.subject == "Hello")
        #expect(kept.bodyText == "Body text")
        DraftBox.shared.remove(draftID)
    }
}
