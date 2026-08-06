import Testing
import Foundation
import AinkradAppKit
@testable import RavenFeature

/// Split out of `GraphMutationTests.swift`, which crossed the branch's 450-line
/// split threshold once the disjointness hole was closed. The seam is the natural
/// one: that file drives requests through `StubURLProtocol`, this one tests the
/// string mapping with no transport at all.
/// `GraphVocabulary` in isolation: the rendering direction, the reading direction,
/// and the two collisions the prefixes exist to prevent.
@Suite("GraphVocabulary")
@MainActor
struct GraphVocabularyTests {
    private let vocabulary = GraphVocabulary()

    /// Every folder-valued flag renders, and to Graph's OWN `wellKnownName` rather
    /// than to the canonical flag's name. `deleteditems`/`junkemail` are the two
    /// where the plausible-wrong answer (`trash`, `spam`) is the flag's own
    /// spelling.
    /// The reserved folder marker, spelled out once. Every expectation below writes
    /// it in full rather than referencing `GraphVocabulary.folderPrefix`, so an
    /// assertion is never computed by calling the production code it checks.
    private let marker = "\u{1}folder:"

    @Test("every folder flag renders to its Graph wellKnownName under the folder prefix")
    func folderFlagsRender() {
        let rendered: [MailFlag: String?] = [
            .inbox: vocabulary.label(for: .inbox),
            .archive: vocabulary.label(for: .archive),
            .trash: vocabulary.label(for: .trash),
            .spam: vocabulary.label(for: .spam),
            .sent: vocabulary.label(for: .sent),
            .draft: vocabulary.label(for: .draft),
        ]
        #expect(rendered.count == 6)
        #expect(rendered[.inbox] == "\u{1}folder:inbox")
        #expect(rendered[.archive] == "\u{1}folder:archive")
        #expect(rendered[.trash] == "\u{1}folder:deleteditems")
        #expect(rendered[.spam] == "\u{1}folder:junkemail")
        #expect(rendered[.sent] == "\u{1}folder:sentitems")
        #expect(rendered[.draft] == "\u{1}folder:drafts")
        // Never nil, unlike IMAP's: every Graph mailbox has all six, so there is no
        // account where `.archive` is dropped and an archive silently no-ops.
        #expect(rendered.values.allSatisfy { $0 != nil })
    }

    /// The collision the `folder:` prefix exists for. A user category named exactly
    /// `archive` is a real thing a person can create; with bare well-known names it
    /// would render identically to `MailFlag.archive` and applying it would MOVE
    /// their mail.
    @Test("a category that happens to be spelled like a well-known folder stays a category")
    func bareWellKnownNamesAreNotFolders() {
        #expect(vocabulary.label(for: .user("archive")) == "archive")
        #expect(vocabulary.label(for: .archive) == "\u{1}folder:archive")
        #expect(vocabulary.flag(for: "archive") == .user("archive"))
        #expect(vocabulary.flag(for: "\u{1}folder:archive") == .archive)
        // The readable half of the marker is NOT the marker: a category literally
        // named `folder:archive` — which a caller of the MCP `label` tool could
        // supply — stays a category in both directions. This is the symmetric hole
        // a plain `"folder:"` prefix would have left open, where applying that
        // category would have MOVED the user's mail.
        #expect(vocabulary.label(for: .user("folder:archive")) == "folder:archive")
        #expect(vocabulary.flag(for: "folder:archive") == .user("folder:archive"))
        #expect(GraphVocabulary.wellKnownFolder(in: "folder:archive") == nil)
        // Same for the other five spellings, since only one being wrong is enough.
        #expect(vocabulary.flag(for: "deleteditems") == .user("deleteditems"))
        #expect(vocabulary.flag(for: "inbox") == .user("inbox"))
    }

    /// `.unread` must not render to anything named for `isRead`: the inversion lives
    /// in `applyLabels`, and a vocabulary that expressed the positive polarity would
    /// make `setRead(false)` mark the thread READ.
    @Test("unread renders to the pseudo-flag and reads back as unread")
    func unreadRoundTrips() {
        #expect(vocabulary.label(for: .unread) == "\\Unread")
        #expect(vocabulary.flag(for: "\\Unread") == .unread)
        #expect(vocabulary.label(for: .starred) == "\\Flagged")
        #expect(vocabulary.flag(for: "\\Flagged") == .starred)
        // The derived readers `ThreadMutationApplier` uses agree, which is what
        // makes the local half of a star/mark-read correct.
        #expect(vocabulary.isUnread(labels: ["\\Unread", "Category A"]))
        #expect(vocabulary.isUnread(labels: ["Category A"]) == false)
        #expect(vocabulary.isStarred(labels: ["\\Flagged"]))
    }

    /// The opaque `parentFolderId` that `GraphMapping.labelIDs` stores is not a
    /// canonical anything, and must come back as a user label rather than being
    /// dropped — a label the domain does not understand is still one the provider
    /// must keep.
    @Test("an opaque folder id and an unknown well-known name both read as user labels")
    func unknownStringsSurviveAsUserLabels() {
        #expect(vocabulary.flag(for: "folder-b-id") == .user("folder-b-id"))
        #expect(vocabulary.flag(for: "\u{1}folder:conversationhistory")
                == .user("\u{1}folder:conversationhistory"))
        #expect(vocabulary.flag(for: "\u{1}folder:") == .user("\u{1}folder:"))
        // A server-defined flag shape this build has never heard of routes to a user
        // label too, not to a silent drop.
        #expect(vocabulary.flag(for: "\\Somethingelse") == .user("\\Somethingelse"))
    }

    /// The three kinds are disjoint by construction, which is what lets
    /// `applyLabels` split a rendered mutation on the strings alone.
    @Test("the three string kinds are mutually exclusive")
    func kindsAreDisjoint() {
        let cases: [(String, Bool, String?, Bool)] = [
            ("\\Unread", true, nil, false),
            ("\u{1}folder:archive", false, "archive", false),
            ("Category A", false, nil, true),
            ("archive", false, nil, true),
            // The readable prefix on its own is a category, not a folder — the
            // symmetric half of the disjointness claim.
            ("folder:archive", false, nil, true),
        ]
        #expect(cases.count == 5)
        for (label, isFlag, folder, isCategory) in cases {
            #expect(GraphVocabulary.isSystemFlag(label) == isFlag, "isSystemFlag(\(label))")
            #expect(GraphVocabulary.wellKnownFolder(in: label) == folder,
                    "wellKnownFolder(\(label))")
            #expect(GraphVocabulary.isCategory(label) == isCategory, "isCategory(\(label))")
        }
    }

    /// The second half of what makes the three kinds genuinely disjoint: a
    /// `.user` label that wears the reserved marker anyway, or that is spelled
    /// exactly like one of the two pseudo-flags, is **refused** rather than
    /// rendered — so no deliberately crafted label can be turned into a folder move
    /// or a property write.
    ///
    /// The contrast lines matter as much as the refusals: a near-miss must still
    /// render, or this would be a rule that quietly drops ordinary categories.
    @Test("a category wearing the reserved marker or a pseudo-flag name is refused")
    func reservedCategoryNamesAreRefusedRatherThanRendered() {
        #expect(vocabulary.label(for: .user(marker + "archive")) == nil)
        #expect(vocabulary.label(for: .user(marker)) == nil)
        #expect(vocabulary.label(for: .user("\\Unread")) == nil)
        #expect(vocabulary.label(for: .user("\\Flagged")) == nil)
        // Near misses that must survive: a different backslash keyword, and the
        // readable prefix without the control character.
        #expect(vocabulary.label(for: .user("\\Seen")) == "\\Seen")
        #expect(vocabulary.label(for: .user("folder:archive")) == "folder:archive")
        #expect(vocabulary.label(for: .user("Category A")) == "Category A")
        // Rendered through a whole mutation, which is where the drop actually
        // happens (`LabelVocabulary.render` compactMaps the nils away): the crafted
        // label is gone and the ordinary one beside it is not.
        let rendered = vocabulary.render(FlagMutation(
            threadIDs: ["AAQkCONV-1"],
            add: [.user(marker + "deleteditems"), .user("Category A")]))
        #expect(rendered.add == ["Category A"])
        #expect(rendered.remove.isEmpty)
    }

    /// `moveDestination`'s whole job: the added folder wins, and a bare removal
    /// derives the archive. Unit-tested directly as well as through the requests
    /// above, because the derivation is the part a reader would get wrong.
    @Test("a move destination prefers the added folder and derives archive from a removal")
    func moveDestinationRules() {
        #expect(GraphProvider.moveDestination(added: ["deleteditems"],
                                              removed: ["inbox"]) == "deleteditems")
        #expect(GraphProvider.moveDestination(added: [], removed: ["inbox"]) == "archive")
        #expect(GraphProvider.moveDestination(added: [], removed: []) == nil)
    }

    /// The carried tripwire from Task 2, now satisfied: `.graph` resolves, and it
    /// resolves to Graph's vocabulary rather than to Gmail's identity mapping.
    @Test("the resolver answers for .graph, and not with Gmail's mapping")
    func resolverAnswersForGraph() throws {
        let resolved = try #require(LabelVocabularyResolver.vocabulary(for: .graph))
        #expect(resolved.label(for: .unread) == "\\Unread")
        #expect(resolved.label(for: .archive) == "\u{1}folder:archive")
        // Gmail's answers for the same two flags, which this must NOT be.
        #expect(GmailVocabulary().label(for: .unread) == "UNREAD")
        #expect(GmailVocabulary().label(for: .archive) == nil)
    }
}
