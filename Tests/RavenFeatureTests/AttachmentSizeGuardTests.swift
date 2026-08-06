import Testing
import Foundation
@testable import RavenFeature

@Suite("Attachment size guard")
struct AttachmentSizeGuardTests {
    @Test("attachments within budget produce no refusal")
    func withinBudget() {
        let small = OutgoingAttachment(filename: "a.txt", mimeType: "text/plain",
                                       data: Data(repeating: 1, count: 1024))
        #expect(AttachmentSizeGuard.refusalMessage(for: [small]) == nil)
    }

    @Test("an oversized attachment set is refused with a clear, user-facing message")
    func oversizedIsRefused() {
        let huge = OutgoingAttachment(filename: "huge.bin", mimeType: "application/octet-stream",
                                      data: Data(repeating: 1, count: 20_000_000))
        let message = AttachmentSizeGuard.refusalMessage(for: [huge])
        #expect(message != nil)
        #expect(message?.contains("MB") == true)
    }

    @Test("SendAttempt.send throws before enqueueing when attachments are too large")
    @MainActor
    func sendAttemptRefusesBeforeQueueing() async throws {
        let provider = FakeMailProvider()
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: provider)
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let huge = OutgoingAttachment(filename: "huge.bin", mimeType: "application/octet-stream",
                                      data: Data(repeating: 1, count: 20_000_000))
        let message = OutgoingMessage(to: [MailAddress(email: "b@example.com")],
                                      subject: "s", bodyText: "b", attachments: [huge])
        await #expect(throws: MailError.attachmentsTooLarge(message: AttachmentSizeGuard
            .refusalMessage(for: [huge]) ?? "")) {
            _ = try await SendAttempt.send(message, draftID: nil, outbox: outbox, store: store,
                                           drain: outbox.drain)
        }
        #expect(provider.sentMessages.isEmpty)
    }
}
