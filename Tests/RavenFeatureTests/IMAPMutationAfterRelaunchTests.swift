import Testing
import Foundation
@testable import RavenFeature

/// Archiving a real thread updated Raven and left the mail sitting in Gmail's
/// inbox. Found by the A15 live-verification item, which exists because this
/// failure is completely invisible locally.
///
/// The cause was a LIFETIME mismatch that no existing test could express.
/// `IMAPMessageIndex` is a plain in-memory actor created with the provider and
/// filled only by a walk, so every relaunch starts with it empty — and a delta sync
/// refills it only for threads that CHANGED, so an older thread's locators never
/// come back without a full backfill. `applyLabels` read the empty index, found no
/// UIDs, and **returned normally**. The caller had already applied the change to the
/// local store optimistically, so Raven showed the thread archived and the server
/// was never told.
///
/// Why 1088 tests missed it: `IMAPProviderMutationTests.applying` calls
/// `fetchThreads` before every mutation, so the index is always warm. That is a
/// perfectly reasonable test setup which happens to encode the one precondition
/// production cannot guarantee. These tests never walk first.
@Suite("IMAP mutations survive a relaunch")
struct IMAPMutationAfterRelaunchTests {

    private static let coldThread = "imapt-88099c778cf88fc9"
    /// UID 10 in INBOX at the fixtures' `UIDVALIDITY`, spelled the way a stored
    /// `MailMessage.id` spells it — which is exactly what the production fallback
    /// decodes.
    private static let storedLocator = IMAPMessageLocator(mailbox: "INBOX",
                                                          uidValidity: 7, uid: 10)

    // MARK: - The defect

    @Test("a cold index with nothing stored REFUSES rather than reporting success")
    func coldIndexWithNothingStoredThrows() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(
            steps: [.init("SELECT \"INBOX\"", "imap-provider-select")])
        let mutation = IMAPVocabulary(directory: try IMAPProviderHarness.directory())
            .render(ThreadAction.archive.mutation(threadIDs: [Self.coldThread]))

        await #expect(throws: MailError.unknownThread(Self.coldThread)) {
            try await provider.applyLabels(mutation)
        }

        // The wire is the real assertion. Before the fix this call returned
        // normally having sent NOTHING — which is precisely "archived in Raven,
        // still in Gmail". A test that only checked the return value would have
        // passed against the bug.
        let wire = await transport.sentText
        #expect(!wire.contains("UID MOVE"))
        #expect(!wire.contains("UID STORE"))
        await session.close()
    }

    @Test("a cold index falls back to the store and the mutation reaches the wire")
    func coldIndexResolvesLocatorsFromTheStore() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(
            steps: [.init("SELECT \"INBOX\"", "imap-provider-select"), .init("UID STORE")],
            storedLocators: { _ in [Self.storedLocator] })
        let mutation = IMAPVocabulary(directory: try IMAPProviderHarness.directory())
            .render(ThreadAction.star(true).mutation(threadIDs: [Self.coldThread]))

        _ = await IMAPProviderHarness.expect("applyLabels") {
            try await provider.applyLabels(mutation)
        }

        let wire = await transport.sentText
        #expect(wire.contains("UID STORE 10 +FLAGS.SILENT (\\Flagged)"))
        await session.close()
    }

    @Test("an id this build did not mint is dropped rather than guessed at")
    func unrecognisedMessageIDsDoNotBecomeUIDs() async throws {
        let (provider, transport, session, _) = try await IMAPProviderHarness.provider(
            steps: [.init("SELECT \"INBOX\"", "imap-provider-select")],
            // A Gmail id on a thread predating this IMAP account, and a truncated
            // string. `IMAPMessageLocator(encoded:)` refuses both, so the fallback
            // yields nothing — acting on a guessed UID would mutate somebody else's
            // message.
            storedLocators: { _ in
                ["18c9f0a2b3d4e5f6", "not-a-locator"]
                    .compactMap { IMAPMessageLocator(encoded: $0) }
            })
        let mutation = IMAPVocabulary(directory: try IMAPProviderHarness.directory())
            .render(ThreadAction.archive.mutation(threadIDs: [Self.coldThread]))

        await #expect(throws: MailError.unknownThread(Self.coldThread)) {
            try await provider.applyLabels(mutation)
        }
        let wire = await transport.sentText
        #expect(!wire.contains("UID MOVE"))
        await session.close()
    }

    // MARK: - The same dependency on the read path

    @Test("fetchThread on a cold index reports unknown when nothing is stored")
    func fetchThreadIsHonestWhenColdAndEmpty() async throws {
        let (provider, _, session, _) = try await IMAPProviderHarness.provider(
            steps: [.init("SELECT \"INBOX\"", "imap-provider-select")])
        await #expect(throws: MailError.unknownThread(Self.coldThread)) {
            _ = try await provider.fetchThread(id: Self.coldThread)
        }
        await session.close()
    }
}
