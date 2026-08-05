import Testing
import Foundation
@testable import RavenFeature

/// Task 13: IMAP's two kinds of provider string, and the read-flag inversion.
@Suite("IMAP vocabulary")
struct IMAPVocabularyTests {

    private static func vocabulary() throws -> IMAPVocabulary {
        IMAPVocabulary(directory: try IMAPProviderHarness.directory())
    }

    @Test("folder-valued flags render to the account's OWN mailbox names")
    func folderFlagsUseTheDirectory() throws {
        let vocabulary = try Self.vocabulary()
        // This account's archive is `Folder B` and its trash `Folder C`. Anything
        // that rendered `"Archive"`/`"Trash"` would be guessing, and the guess is
        // what aims a delete at a mailbox that does not exist.
        #expect(vocabulary.label(for: .archive) == "Folder B")
        #expect(vocabulary.label(for: .trash) == "Folder C")
        #expect(vocabulary.label(for: .inbox) == "INBOX")
        // No `\Sent`, no `\Junk` in this account: nil, so the mutation refuses.
        #expect(vocabulary.label(for: .sent) == nil)
        #expect(vocabulary.label(for: .spam) == nil)
    }

    @Test("the read flag renders to the \\Unseen pseudo-flag, never to \\Seen")
    func unreadRendersToThePseudoFlag() throws {
        let vocabulary = try Self.vocabulary()
        // Rendering `.unread` as `\Seen` inverts every mark-read/mark-unread on the
        // wire: `ThreadAction.setRead(false)` emits `add: [.unread]`, which would
        // reach the server as `+FLAGS (\Seen)`.
        #expect(vocabulary.label(for: .unread) == "\\Unseen")
        #expect(vocabulary.label(for: .unread) != "\\Seen")
        #expect(vocabulary.flag(for: "\\Unseen") == .unread)
        // `\Seen` is the OPPOSITE polarity and has no canonical flag, so it must not
        // read back as `.unread`.
        #expect(vocabulary.flag(for: "\\Seen") == .user("\\Seen"))
    }

    @Test("system flags and mailbox names are told apart by the leading backslash")
    func systemFlagsAreDistinguishedStructurally() throws {
        #expect(IMAPVocabulary.isSystemFlag("\\Flagged"))
        #expect(IMAPVocabulary.isSystemFlag("\\SomeVendorFlag"))
        // A mailbox name never starts with a backslash (RFC 3501 reserves it for
        // flags), which is why the test is structural rather than a lookup table —
        // a server-defined keyword this build has never heard of still routes to
        // `UID STORE` rather than to `UID MOVE`.
        #expect(!IMAPVocabulary.isSystemFlag("Folder B"))
        #expect(!IMAPVocabulary.isSystemFlag("INBOX"))
    }

    @Test("a mutation round-trips through render and back")
    func renderRoundTrips() throws {
        let vocabulary = try Self.vocabulary()
        let rendered = vocabulary.render(
            ThreadAction.trash.mutation(threadIDs: ["imapt-1"]))
        #expect(rendered.add == ["Folder C"])
        #expect(rendered.remove == ["INBOX"])
        #expect(vocabulary.flags(from: rendered.add) == [.trash])
        #expect(vocabulary.flags(from: rendered.remove) == [.inbox])
    }

    @Test("a mailbox with no canonical meaning is a user label, never dropped")
    func unknownMailboxIsAUserLabel() throws {
        #expect(try Self.vocabulary().flag(for: "Folder D") == .user("Folder D"))
        #expect(try Self.vocabulary().flag(for: "Folder Z") == .user("Folder Z"))
    }

    @Test("\\Deleted reads as trash, matching the fetch parser")
    func deletedReadsAsTrash() throws {
        // `IMAPFetchParser.canonicalFlags` maps `\Deleted` to `.trash`; a vocabulary
        // that disagreed would make a stored flag list and a freshly fetched one
        // describe the same message differently.
        #expect(try Self.vocabulary().flag(for: "\\Deleted") == .trash)
    }

    @Test("an empty directory still renders flags but refuses every folder")
    func emptyDirectoryRefusesFolders() {
        // The default, and the reason `LabelVocabularyResolver` still answers nil for
        // `.imap`: with no directory, `archive` renders to an empty mutation, which a
        // caller cannot distinguish from a successful archive.
        let vocabulary = IMAPVocabulary()
        #expect(vocabulary.label(for: .starred) == "\\Flagged")
        #expect(vocabulary.label(for: .archive) == nil)
        #expect(vocabulary.label(for: .inbox) == nil)
        #expect(vocabulary.render(ThreadAction.archive.mutation(threadIDs: ["t"]))
            == LabelMutation(threadIDs: ["t"], add: [], remove: []))
        #expect(LabelVocabularyResolver.vocabulary(for: .imap) == nil)
    }
}
