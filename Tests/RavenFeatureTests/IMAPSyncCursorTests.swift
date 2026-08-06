import Testing
import Foundation
@testable import RavenFeature

@Suite("IMAP composite sync cursor")
struct IMAPSyncCursorTests {

    private func sample() -> IMAPSyncCursor {
        var cursor = IMAPSyncCursor()
        cursor.advance(mailbox: "INBOX", uidValidity: 111, uidNext: 42, highestModSeq: 9001)
        cursor.advance(mailbox: "Folder A", uidValidity: 222, uidNext: 7)
        return cursor
    }

    // MARK: - Round trip

    @Test("the cursor round-trips through a String")
    func roundTripsThroughString() throws {
        let encoded = sample().encoded()
        let decoded = IMAPSyncCursor(encoded: encoded)

        // Asserted field-by-field against literals rather than against
        // `sample()` — comparing the decode to the value that produced it would
        // pass even if both sides were empty.
        #expect(decoded.mailboxes.keys.sorted() == ["Folder A", "INBOX"])
        let inbox = try #require(decoded.mailboxes["INBOX"])
        #expect(inbox.uidValidity == 111)
        #expect(inbox.uidNext == 42)
        #expect(inbox.highestModSeq == 9001)
        let folder = try #require(decoded.mailboxes["Folder A"])
        #expect(folder.uidValidity == 222)
        #expect(folder.uidNext == 7)
        // Not offered by this mailbox's server — nil, never 0, because
        // `CHANGEDSINCE 0` is a legal command meaning something else.
        #expect(folder.highestModSeq == nil)
    }

    @Test("encoding is stable, so an unchanged cursor re-saves byte-for-byte")
    func encodingIsStable() {
        // Pinned to the literal bytes rather than to a second call to
        // `encoded()`: dictionary iteration order is stable within a process, so
        // comparing two encodes of the same value would pass even with key
        // sorting removed — and it is a *re-save across launches* that must not
        // look changed.
        #expect(sample().encoded() == """
        {"mailboxes":{"Folder A":{"uidnext":7,"uidvalidity":222},\
        "INBOX":{"highestmodseq":9001,"uidnext":42,"uidvalidity":111}},"v":1}
        """)
    }

    @Test("the cursor survives storage in an existing accounts document")
    func survivesAccountsDocument() throws {
        // The `accounts` document is an ARRAY of `MailAccount`, and the cursor
        // travels in the `syncCursor` string that already exists — no store
        // schema change. Two accounts, so a decode failure that stranded the
        // array would be visible.
        let accounts = [
            MailAccount(id: "acct-imap", provider: .imap, address: "a@example.test",
                        displayName: "Account One", syncCursor: sample().encoded(),
                        state: .ready),
            MailAccount(id: "acct-gmail", provider: .gmail, address: "b@example.test",
                        displayName: "Account Two", syncCursor: "981223", state: .ready),
        ]
        let data = try JSONEncoder().encode(accounts)
        let reloaded = try JSONDecoder().decode([MailAccount].self, from: data)

        #expect(reloaded.map(\.id) == ["acct-imap", "acct-gmail"])
        let imapAccount = try #require(reloaded.first { $0.id == "acct-imap" })
        let cursor = IMAPSyncCursor(encoded: imapAccount.syncCursor)
        #expect(cursor.mailboxes["INBOX"]?.uidNext == 42)
        #expect(cursor.mailboxes["INBOX"]?.uidValidity == 111)

        // A Gmail `historyId` is not an IMAP cursor and must read as empty
        // rather than as garbage — a backfill, never a wrong fetch.
        let gmailAccount = try #require(reloaded.first { $0.id == "acct-gmail" })
        #expect(IMAPSyncCursor(encoded: gmailAccount.syncCursor).isEmpty)
    }

    @Test("an absent or unreadable cursor reads as empty instead of throwing")
    func unreadableCursorIsEmpty() {
        #expect(IMAPSyncCursor(encoded: nil).isEmpty)
        #expect(IMAPSyncCursor(encoded: "").isEmpty)
        #expect(IMAPSyncCursor(encoded: "not json at all").isEmpty)
        #expect(IMAPSyncCursor(encoded: "{\"mailboxes\":").isEmpty)
    }

    // MARK: - UIDVALIDITY

    @Test("an unchanged UIDVALIDITY resumes from the stored position")
    func unchangedValidityResumes() {
        var cursor = sample()
        let decision = cursor.reconcile(mailbox: "INBOX", uidValidity: 111)
        #expect(decision == .resume(IMAPMailboxSyncState(uidValidity: 111, uidNext: 42,
                                                         highestModSeq: 9001)))
        #expect(decision.requiresFullWalk == false)
        #expect(cursor.mailboxes["INBOX"]?.uidNext == 42)
    }

    @Test("a UIDVALIDITY change resets that mailbox and no other")
    func validityChangeIsPerMailbox() throws {
        var cursor = sample()
        let decision = cursor.reconcile(mailbox: "INBOX", uidValidity: 999)

        // Reported, never silently reused: the previous generation comes back
        // with the decision so the re-walk is an event a caller can log.
        #expect(decision == .rewalk(previousUIDValidity: 111))
        #expect(decision.requiresFullWalk)

        let inbox = try #require(cursor.mailboxes["INBOX"])
        #expect(inbox.uidValidity == 999)
        #expect(inbox.uidNext == 1)
        #expect(inbox.highestModSeq == nil)

        // The point of the whole design: one re-provisioned folder must not
        // cost a full-account re-walk.
        let folder = try #require(cursor.mailboxes["Folder A"])
        #expect(folder.uidValidity == 222)
        #expect(folder.uidNext == 7)
        #expect(cursor.decision(for: "Folder A", uidValidity: 222)
                == .resume(IMAPMailboxSyncState(uidValidity: 222, uidNext: 7)))
    }

    @Test("a never-seen mailbox is a full walk, and is recorded as such")
    func unseenMailboxIsFullWalk() throws {
        var cursor = sample()
        #expect(cursor.decision(for: "Folder B", uidValidity: 333) == .fullWalk)
        #expect(cursor.reconcile(mailbox: "Folder B", uidValidity: 333) == .fullWalk)
        let created = try #require(cursor.mailboxes["Folder B"])
        #expect(created.uidValidity == 333)
        #expect(created.uidNext == 1)
    }

    @Test("detection does not mutate, so a change can be reported before it is applied")
    func decisionIsPure() {
        let cursor = sample()
        #expect(cursor.decision(for: "INBOX", uidValidity: 999)
                == .rewalk(previousUIDValidity: 111))
        // Unchanged: the report happened without discarding anything.
        #expect(cursor.mailboxes["INBOX"]?.uidValidity == 111)
        #expect(cursor.mailboxes["INBOX"]?.uidNext == 42)
        #expect(cursor == sample())
    }

    // MARK: - advance

    @Test("advance is monotonic within a generation and starts over across one")
    func advanceIsMonotonic() throws {
        var cursor = sample()
        cursor.advance(mailbox: "INBOX", uidValidity: 111, uidNext: 10, highestModSeq: 1)
        let held = try #require(cursor.mailboxes["INBOX"])
        #expect(held.uidNext == 42)
        #expect(held.highestModSeq == 9001)

        cursor.advance(mailbox: "INBOX", uidValidity: 111, uidNext: 50, highestModSeq: 9100)
        let moved = try #require(cursor.mailboxes["INBOX"])
        #expect(moved.uidNext == 50)
        #expect(moved.highestModSeq == 9100)

        // A new generation is not a continuation of the old one.
        cursor.advance(mailbox: "INBOX", uidValidity: 112, uidNext: 3)
        let reset = try #require(cursor.mailboxes["INBOX"])
        #expect(reset.uidValidity == 112)
        #expect(reset.uidNext == 3)
        #expect(reset.highestModSeq == nil)
    }

    @Test("a mailbox that no longer exists is forgotten, not re-walked")
    func forgetRemovesMailbox() {
        var cursor = sample()
        cursor.forget(mailbox: "Folder A")
        #expect(cursor.mailboxes.keys.sorted() == ["INBOX"])
        #expect(cursor.decision(for: "Folder A", uidValidity: 222) == .fullWalk)
    }

    // MARK: - Forward compatibility

    @Test("a cursor written by a future build decodes to a usable subset")
    func futureCursorDecodesToUsableSubset() throws {
        // Written by a newer build: a higher version, an unknown top-level key,
        // an unknown per-mailbox key, one entry that is not an object at all,
        // and one object with no `uidvalidity`.
        let future = """
        {"v":9,"unknownTopLevel":{"x":1},"mailboxes":{\
        "INBOX":{"uidvalidity":111,"uidnext":42,"highestmodseq":9001,"quotaRoot":"root"},\
        "Folder A":{"uidvalidity":222},\
        "Folder B":"a future scalar",\
        "Folder C":{"uidnext":5}}}
        """
        let cursor = IMAPSyncCursor(encoded: future)

        // Usable subset: the two decodable mailboxes survive with correct
        // values; the two this build cannot make sense of are dropped rather
        // than stranding their siblings.
        #expect(cursor.mailboxes.keys.sorted() == ["Folder A", "INBOX"])
        let inbox = try #require(cursor.mailboxes["INBOX"])
        #expect(inbox.uidValidity == 111)
        #expect(inbox.uidNext == 42)
        #expect(inbox.highestModSeq == 9001)

        // A position with no `uidnext` degrades to a re-walk from UID 1, which
        // costs a walk and cannot produce a wrong fetch.
        let folderA = try #require(cursor.mailboxes["Folder A"])
        #expect(folderA.uidValidity == 222)
        #expect(folderA.uidNext == 1)
        #expect(cursor.version == 9)
        #expect(cursor.decision(for: "Folder A", uidValidity: 222).requiresFullWalk == false)
    }

    @Test("a future cursor with no mailboxes key still decodes")
    func futureCursorWithoutMailboxes() {
        let cursor = IMAPSyncCursor(encoded: "{\"v\":9,\"somethingElse\":true}")
        #expect(cursor.isEmpty)
        #expect(cursor.version == 9)
    }
}
