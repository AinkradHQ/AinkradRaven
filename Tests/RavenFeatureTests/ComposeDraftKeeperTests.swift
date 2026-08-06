import Testing
import Foundation
@testable import RavenFeature

/// The autosave contract. These cover the case a view-lifecycle callback
/// structurally cannot — an edit with no dismissal at all — plus the ordering
/// that would otherwise reintroduce a ghost draft for a message already sent.
@MainActor
@Suite("Compose draft autosave")
struct ComposeDraftKeeperTests {
    private func message(_ subject: String, body: String = "") -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "bea@example.com")], subject: subject,
                        bodyText: body)
    }

    @Test("an edit with no dismissal at all leaves a recoverable draft")
    func editWithoutDismissalIsRecoverable() {
        let box = DraftBox()
        let keeper = ComposeDraftKeeper(box: box)

        // No close, no disappear, no send — the exact case `onDisappear` cannot
        // cover, and the reason the guarantee moved off it.
        keeper.save(message("half-typed"), generation: keeper.generation)

        #expect(box.all().count == 1)
        #expect(box.all().first?.message.subject == "half-typed")
        #expect(keeper.draftID == box.all().first?.id)
    }

    @Test("two successive edits update one draft rather than creating two")
    func successiveEditsUpdateOneDraft() {
        let box = DraftBox()
        let keeper = ComposeDraftKeeper(box: box)

        keeper.save(message("first", body: "a"), generation: keeper.generation)
        let firstID = keeper.draftID
        keeper.save(message("second", body: "ab"), generation: keeper.generation)

        #expect(box.all().count == 1)
        #expect(keeper.draftID == firstID)
        #expect(box.all().first?.message.subject == "second")
        #expect(box.all().first?.message.bodyText == "ab")
    }

    @Test("a send removes the draft and a pending autosave does not bring it back")
    func retiredSessionRefusesALateWrite() {
        let box = DraftBox()
        let keeper = ComposeDraftKeeper(box: box)
        keeper.save(message("outgoing"), generation: keeper.generation)
        let draftID = keeper.draftID!

        // An autosave that was already scheduled when Send was pressed reads the
        // generation BEFORE waiting — this is that captured value.
        let scheduledGeneration = keeper.generation

        // The send: the draft is removed (by `SendAttempt` on `.sent`, or by the
        // caller when the message is held on an outbox entry), then retired.
        box.remove(draftID)
        keeper.retire()

        // The late write lands now. It must be refused, not re-create the entry.
        let result = keeper.save(message("outgoing"), generation: scheduledGeneration)
        #expect(result == nil)
        #expect(box.all().isEmpty)
        #expect(keeper.draftID == nil)

        // And the session is still usable: the next real edit starts a NEW draft
        // rather than being permanently poisoned by the retire.
        keeper.save(message("next message"), generation: keeper.generation)
        #expect(box.all().count == 1)
        #expect(box.all().first?.message.subject == "next message")
        #expect(keeper.draftID != draftID)
    }

    @Test("reply context survives the autosave round trip")
    func replyThreadingSurvivesTheRoundTrip() {
        let box = DraftBox()
        let keeper = ComposeDraftKeeper(box: box)
        let reference = ComposeThreadReference(threadID: "t-7", accountID: "acct-b",
                                              lastMessageRFC822ID: "<m-3@example.com>")

        // Exactly what the composer autosaves: the typed message with its
        // context's stamps already applied.
        let stamped = ComposeContext.reply(mode: .replyAll, thread: reference)
            .stamp(message("Re: hello", body: "draft body"), fallbackAccountID: "acct-a")
        keeper.save(stamped, generation: keeper.generation)

        // A restored draft that had lost these would silently start a new
        // conversation from the wrong mailbox.
        let restored = box.all().first?.message
        #expect(restored?.threadID == "t-7")
        #expect(restored?.inReplyToMessageID == "<m-3@example.com>")
        #expect(restored?.accountID == "acct-b")
        #expect(restored?.bodyText == "draft body")
    }

    @Test("adopting an existing draft updates it instead of forking a copy")
    func adoptUpdatesInPlace() throws {
        let box = DraftBox()
        let existingID = try box.save(message("from the rail"))
        let keeper = ComposeDraftKeeper(box: box)

        keeper.adopt(existingID)
        keeper.save(message("edited in the composer"), generation: keeper.generation)

        #expect(box.all().count == 1)
        #expect(keeper.draftID == existingID)
        #expect(box.draft(existingID)?.subject == "edited in the composer")
    }
}

/// The compose overlay's width, which the shell derives from the room it has.
/// A flat 780 pushed the modal's panel border over its own content when Raven
/// ran in the host's narrow overlay presentation.
@MainActor
@Suite("Compose overlay width")
struct ComposeOverlayWidthTests {
    @Test("a roomy pane gets the ideal width, with the scrim still visible either side")
    func roomyPaneUsesIdealWidth() {
        #expect(RavenShell.composeWidth(in: 1400) == 780)
    }

    @Test("a narrow pane shrinks to fit instead of overflowing")
    func narrowPaneShrinks() {
        // 700 - 2 * AinkradSpacing.xl (24) = 652.
        #expect(RavenShell.composeWidth(in: 700) == 652)
    }

    @Test("an absurdly narrow or unmeasured pane falls back to the floor rather than zero or negative")
    func degenerateWidthsFallBackToTheFloor() {
        #expect(RavenShell.composeWidth(in: 0) == 360)
        #expect(RavenShell.composeWidth(in: 40) == 360)
    }
}
