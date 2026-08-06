import Testing
import Foundation
@testable import RavenFeature

/// The canonical flag vocabulary and its per-provider translation.
///
/// The load-bearing suite here is `GmailIdentityMapping`: the expected strings
/// were copied out of `ThreadAction.mutation` as it stood at commit 42b08bf,
/// before the canonical flags existed, and are asserted byte-for-byte. If any
/// of them changes, this refactor changed Gmail's behaviour, which it must not.
@Suite struct MailFlagVocabularyTests {

    // MARK: Gmail identity mapping — pre-change values, byte for byte

    @Suite struct GmailIdentityMapping {
        let vocabulary = GmailVocabulary()

        /// Pre-change: `LabelMutation(threadIDs: threadIDs, remove: ["INBOX"])`
        @Test func archiveRendersExactlyAsBefore() {
            let rendered = ThreadAction.archive.labelMutation(threadIDs: ["t1"])
            #expect(rendered.threadIDs == ["t1"])
            #expect(rendered.add == [])
            #expect(rendered.remove == ["INBOX"])
        }

        /// Pre-change: `LabelMutation(threadIDs: threadIDs, add: ["TRASH"], remove: ["INBOX"])`
        @Test func trashRendersExactlyAsBefore() {
            let rendered = ThreadAction.trash.labelMutation(threadIDs: ["t1", "t2"])
            #expect(rendered.threadIDs == ["t1", "t2"])
            #expect(rendered.add == ["TRASH"])
            #expect(rendered.remove == ["INBOX"])
        }

        /// Pre-change: `add: ["STARRED"]` / `remove: ["STARRED"]`
        @Test func starRendersExactlyAsBefore() {
            let on = ThreadAction.star(true).labelMutation(threadIDs: ["t1"])
            #expect(on.add == ["STARRED"])
            #expect(on.remove == [])
            let off = ThreadAction.star(false).labelMutation(threadIDs: ["t1"])
            #expect(off.add == [])
            #expect(off.remove == ["STARRED"])
        }

        /// Pre-change: `remove: ["UNREAD"]` / `add: ["UNREAD"]`
        @Test func setReadRendersExactlyAsBefore() {
            let read = ThreadAction.setRead(true).labelMutation(threadIDs: ["t1"])
            #expect(read.add == [])
            #expect(read.remove == ["UNREAD"])
            let unread = ThreadAction.setRead(false).labelMutation(threadIDs: ["t1"])
            #expect(unread.add == ["UNREAD"])
            #expect(unread.remove == [])
        }

        /// Pre-change: `add`/`remove` passed straight through, in order.
        @Test func labelPassesCallerStringsThroughUnchanged() {
            let action = ThreadAction.label(add: ["Label_17", "IMPORTANT"], remove: ["CATEGORY_PROMOTIONS"])
            let rendered = action.labelMutation(threadIDs: ["t1"])
            #expect(rendered.add == ["Label_17", "IMPORTANT"])
            #expect(rendered.remove == ["CATEGORY_PROMOTIONS"])
        }

        /// A caller-supplied string that happens to BE a system label still
        /// renders back identically — the identity mapping holds in both
        /// directions, so the MCP `label` tool cannot change meaning.
        @Test func systemLabelSuppliedByCallerRoundTrips() {
            let rendered = ThreadAction.label(add: ["INBOX"], remove: ["TRASH"])
                .labelMutation(threadIDs: ["t1"])
            #expect(rendered.add == ["INBOX"])
            #expect(rendered.remove == ["TRASH"])
        }

        @Test func everySystemFlagIsItsOwnGmailLabel() {
            #expect(vocabulary.label(for: .inbox) == "INBOX")
            #expect(vocabulary.label(for: .unread) == "UNREAD")
            #expect(vocabulary.label(for: .starred) == "STARRED")
            #expect(vocabulary.label(for: .trash) == "TRASH")
            #expect(vocabulary.label(for: .spam) == "SPAM")
            #expect(vocabulary.label(for: .sent) == "SENT")
            #expect(vocabulary.label(for: .draft) == "DRAFT")
            #expect(vocabulary.label(for: .user("Label_17")) == "Label_17")
        }

        /// Gmail archives by removing INBOX; there is no label to add, and a
        /// stray `"ARCHIVE"` string must never be invented.
        @Test func archiveHasNoGmailLabelAndIsDroppedFromRendering() {
            #expect(vocabulary.label(for: .archive) == nil)
            let rendered = vocabulary.render(
                FlagMutation(threadIDs: ["t1"], add: [.archive], remove: [.inbox]))
            #expect(rendered.add == [])
            #expect(rendered.remove == ["INBOX"])
        }

        @Test func labelsReadBackToTheFlagsTheyAlwaysMeant() {
            #expect(vocabulary.flag(for: "INBOX") == .inbox)
            #expect(vocabulary.flag(for: "UNREAD") == .unread)
            #expect(vocabulary.flag(for: "STARRED") == .starred)
            #expect(vocabulary.flag(for: "TRASH") == .trash)
            #expect(vocabulary.flag(for: "SPAM") == .spam)
            #expect(vocabulary.flag(for: "SENT") == .sent)
            #expect(vocabulary.flag(for: "DRAFT") == .draft)
        }

        /// An unknown label is carried as a user label, never dropped.
        @Test func unknownLabelBecomesAUserLabel() {
            #expect(vocabulary.flag(for: "CATEGORY_FORUMS") == .user("CATEGORY_FORUMS"))
            #expect(vocabulary.flag(for: "Label_9") == .user("Label_9"))
        }

        /// Case matters to Gmail's system labels, so a lowercase lookalike is a
        /// user label — mapping it to `.inbox` would be a behaviour change.
        @Test func systemLabelMatchingIsCaseSensitive() {
            #expect(vocabulary.flag(for: "inbox") == .user("inbox"))
        }
    }

    // MARK: Canonical mutations from ThreadAction

    @Suite struct CanonicalMutations {
        @Test func actionsNameStatesNotProviderLabels() {
            #expect(ThreadAction.archive.mutation(threadIDs: ["t1"])
                == FlagMutation(threadIDs: ["t1"], remove: [.inbox]))
            #expect(ThreadAction.trash.mutation(threadIDs: ["t1"])
                == FlagMutation(threadIDs: ["t1"], add: [.trash], remove: [.inbox]))
            #expect(ThreadAction.star(true).mutation(threadIDs: ["t1"])
                == FlagMutation(threadIDs: ["t1"], add: [.starred]))
            #expect(ThreadAction.setRead(true).mutation(threadIDs: ["t1"])
                == FlagMutation(threadIDs: ["t1"], remove: [.unread]))
            #expect(ThreadAction.setRead(false).mutation(threadIDs: ["t1"])
                == FlagMutation(threadIDs: ["t1"], add: [.unread]))
        }

        /// No Gmail spelling survives on the canonical side.
        @Test func canonicalTokensAreProviderIndependent() {
            let tokens = ThreadAction.trash.mutation(threadIDs: ["t1"])
                .add.map(\.canonicalToken) + ThreadAction.trash.mutation(threadIDs: ["t1"])
                .remove.map(\.canonicalToken)
            #expect(tokens == ["trash", "inbox"])
        }
    }

    // MARK: MailFlag itself

    @Suite struct FlagCoding {
        @Test func everyFlagRoundTripsThroughItsToken() {
            let flags: [MailFlag] = [.inbox, .unread, .starred, .trash, .spam,
                                     .sent, .draft, .archive, .user("Label_17")]
            for flag in flags {
                #expect(MailFlag(canonicalToken: flag.canonicalToken) == flag)
            }
        }

        @Test func flagRoundTripsThroughJSON() throws {
            let flags: [MailFlag] = [.inbox, .unread, .user("Label_17")]
            let data = try JSONEncoder().encode(flags)
            #expect(String(data: data, encoding: .utf8) == #"["inbox","unread","user:Label_17"]"#)
            #expect(try JSONDecoder().decode([MailFlag].self, from: data) == flags)
        }

        /// Forward compatibility, matching `OutgoingMessage`'s decoder rule: a
        /// token written by a future build decodes to something usable rather
        /// than throwing.
        @Test func unknownTokenDecodesAsAUserLabelRatherThanThrowing() throws {
            let data = Data(#"["snoozed"]"#.utf8)
            #expect(try JSONDecoder().decode([MailFlag].self, from: data) == [.user("snoozed")])
        }

        /// A user label whose text collides with a canonical token still
        /// round-trips, because the `user:` prefix disambiguates it.
        @Test func userLabelNamedLikeACanonicalTokenRoundTrips() {
            #expect(MailFlag(canonicalToken: MailFlag.user("inbox").canonicalToken)
                == .user("inbox"))
        }
    }

    // MARK: Reading stored labels through a vocabulary

    @Suite struct StoredLabelReading {
        let vocabulary = GmailVocabulary()

        @Test func readAndStarredStateComeFromCanonicalFlags() {
            #expect(vocabulary.isUnread(labels: ["INBOX", "UNREAD"]))
            #expect(vocabulary.isUnread(labels: ["INBOX"]) == false)
            #expect(vocabulary.isStarred(labels: ["INBOX", "STARRED"]))
            #expect(vocabulary.isStarred(labels: ["INBOX"]) == false)
        }

        @Test func inboxFilterAgreesWithTheOldLabelComparison() {
            func summary(_ labels: [String]) -> ThreadSummary {
                ThreadSummary(id: "t1", accountID: "a", subject: "Subject 1",
                              participants: [], lastMessageDate: Date(),
                              messageCount: 1, unreadCount: 0, isStarred: false,
                              labelIDs: labels, snippet: "")
            }
            #expect(InboxFilter.isInInbox(summary(["INBOX"])))
            #expect(InboxFilter.isInInbox(summary(["INBOX", "TRASH"])) == false)
            #expect(InboxFilter.isInInbox(summary(["INBOX", "SPAM"])) == false)
            #expect(InboxFilter.isInInbox(summary(["UNREAD"])) == false)
        }
    }

    // MARK: No stored document format change

    /// Canonical flags are a MUTATION-time vocabulary. Nothing about the stored
    /// documents moved, so a `thread-*` document written by the pre-canonical
    /// build must still decode and still render the same read/starred state.
    @Suite @MainActor struct StoredDocumentsAreUnchanged {
        /// A literal `thread-t1` document in the shape the pre-canonical build
        /// wrote: labels as Gmail's own strings.
        private let legacyThreadJSON = """
        {"id":"t1","accountID":"a1","messages":[
          {"id":"m1","threadID":"t1","subject":"Subject 1","date":"2026-02-01T00:00:00Z",
           "isRead":false,"isStarred":true,
           "labelIDs":["INBOX","UNREAD","STARRED"],
           "hasAttachments":false,"snippet":""}]}
        """

        @Test func legacyThreadDocumentStillDecodesWithTheSameState() throws {
            let documents = InMemoryDocumentStore()
            documents.setData(Data(legacyThreadJSON.utf8), forKey: "thread-t1")
            let store = DocumentMailStore(documents: documents)
            let thread = try #require(store.thread("t1"))
            #expect(thread.messages[0].labelIDs == ["INBOX", "UNREAD", "STARRED"])
            #expect(thread.messages[0].isRead == false)
            #expect(thread.messages[0].isStarred)
        }

        /// Applying a canonical mutation to a legacy document writes back
        /// PROVIDER strings, not canonical tokens — the document format is
        /// untouched — and derives read state from the canonical unread flag.
        @Test func mutatingALegacyDocumentKeepsProviderStringsInStorage() throws {
            let documents = InMemoryDocumentStore()
            documents.setData(Data(legacyThreadJSON.utf8), forKey: "thread-t1")
            let store = DocumentMailStore(documents: documents)

            let mutation = ThreadAction.setRead(true).labelMutation(threadIDs: ["t1"])
            ThreadMutationApplier.applyLocally(mutation, store: store)

            let thread = try #require(store.thread("t1"))
            #expect(thread.messages[0].labelIDs == ["INBOX", "STARRED"])
            #expect(thread.messages[0].isRead)
            #expect(thread.messages[0].isStarred)
            let raw = try #require(String(data: documents.storage["thread-t1"] ?? Data(),
                                         encoding: .utf8))
            #expect(raw.contains("\"INBOX\""))
            #expect(raw.contains("unread") == false)   // no canonical token leaked
            #expect(raw.contains("user:") == false)
        }
    }

    // MARK: A non-Gmail vocabulary proves the seam is real

    /// A deliberately non-identity vocabulary — IMAP-shaped — used only to
    /// prove the shared domain code is genuinely translated rather than
    /// accidentally still Gmail-specific. The real `IMAPVocabulary` arrives
    /// with the IMAP provider; this stand-in touches no provider code.
    struct SeenFlagVocabulary: LabelVocabulary {
        func label(for flag: MailFlag) -> String? {
            switch flag {
            case .unread: return "\\Unseen"
            case .starred: return "\\Flagged"
            case .trash: return "Trash"
            case .inbox: return "INBOX-FOLDER"
            case .archive: return "Archive"
            case .spam: return "Junk"
            case .sent: return "Sent"
            case .draft: return "\\Draft"
            case .user(let name): return name
            }
        }
        func flag(for label: String) -> MailFlag {
            switch label {
            case "\\Unseen": return .unread
            case "\\Flagged": return .starred
            case "Trash": return .trash
            case "INBOX-FOLDER": return .inbox
            case "Archive": return .archive
            case "Junk": return .spam
            case "Sent": return .sent
            case "\\Draft": return .draft
            default: return .user(label)
            }
        }
    }

    @Test func anotherVocabularyRendersTheSameActionDifferently() {
        let rendered = SeenFlagVocabulary().render(
            ThreadAction.trash.mutation(threadIDs: ["t1"]))
        #expect(rendered.add == ["Trash"])
        #expect(rendered.remove == ["INBOX-FOLDER"])
    }

    /// The old `!labels.contains("UNREAD")` would have called this message
    /// read; canonically it is unread. This is the bug the task exists to
    /// prevent.
    @Test func nonGmailUnreadStateIsReadCorrectly() {
        #expect(SeenFlagVocabulary().isUnread(labels: ["INBOX-FOLDER", "\\Unseen"]))
        #expect(SeenFlagVocabulary().isStarred(labels: ["\\Flagged"]))
    }

    @Test func inboxFilterUsesTheGivenVocabularyNotGmails() {
        let summary = ThreadSummary(id: "t1", accountID: "a", subject: "Subject 1",
                                    participants: [], lastMessageDate: Date(),
                                    messageCount: 1, unreadCount: 1, isStarred: false,
                                    labelIDs: ["INBOX-FOLDER"], snippet: "")
        #expect(InboxFilter.isInInbox(summary, vocabulary: SeenFlagVocabulary()))
        #expect(InboxFilter.isInInbox(summary) == false)
    }
}

/// The resolver is what stops a backend from being mutated through Gmail's label
/// strings. The nil expectations below are a deliberate tripwire, not an
/// oversight: a backend gaining a vocabulary FAILS them, which forces whoever
/// lands it to come here and confirm the wiring rather than discover it in a live
/// mailbox. It has fired twice as intended — Task 16 for `.imap` and Task 20 for
/// `.graph`.
///
/// What the list still asserts, and why it must keep existing: **a backend with no
/// vocabulary refuses rather than guessing.** `.imap` remains on it because
/// `IMAPVocabulary` needs the account's persisted mailbox directory and a bare
/// `ProviderKind` names no account (the account-keyed overload is what answers for
/// it, and refuses an absent OR empty directory — see
/// `IMAPVocabularyTests.emptyDirectoryRefusesFolders` for the silent-no-op that
/// refusal prevents). `.unsupported` remains on it because a kind written by a
/// newer build is precisely the case where guessing is least defensible.
///
/// `.graph` left the list because `GraphVocabulary` needs no directory at all:
/// every folder string it renders is a Graph `wellKnownName`, present in every
/// mailbox and accepted verbatim by `/move`, so it cannot render the empty
/// mutation that makes a missing IMAP directory dangerous. That is a fact about
/// Graph, and `GraphVocabularyTests.resolverAnswersForGraph` pins that what it
/// resolves to is Graph's mapping and not Gmail's.
@Suite("LabelVocabularyResolver")
@MainActor struct LabelVocabularyResolverTests {

    @Test("gmail resolves to the identity vocabulary")
    func gmailResolves() throws {
        let vocabulary = try #require(LabelVocabularyResolver.vocabulary(for: .gmail))
        #expect(vocabulary.label(for: .unread) == "UNREAD")
    }

    /// Apple Mail is read-only and `AppleMailImporter` emits no labels at all,
    /// so there is nothing to translate either way.
    @Test("appleMail resolves, because it has no provider labels to translate")
    func appleMailResolves() throws {
        let vocabulary = try #require(LabelVocabularyResolver.vocabulary(for: .appleMail))
        #expect(vocabulary.flags(from: []).isEmpty)
    }

    @Test("backends with no vocabulary on this overload do not resolve to a wrong one",
          arguments: [MailAccount.ProviderKind.imap, .unsupported("quantumpost")])
    func unbuiltBackendsDoNotResolve(kind: MailAccount.ProviderKind) {
        // The important half is that this is nil rather than Gmail's mapping.
        #expect(LabelVocabularyResolver.vocabulary(for: kind) == nil)
    }

    /// The other half of the rule, kept beside the refusals so the two cannot drift:
    /// `.graph` now resolves, and it resolves to GRAPH's mapping. A regression that
    /// dropped `GraphVocabulary` and let the `.gmail` case catch `.graph` would pass
    /// a bare non-nil check and fail this one.
    @Test("graph resolves from the kind alone, to Graph's own mapping")
    func graphResolvesWithoutADirectory() throws {
        let vocabulary = try #require(LabelVocabularyResolver.vocabulary(for: .graph))
        #expect(vocabulary.label(for: .unread) == "\\Unread")
        #expect(vocabulary.label(for: .trash) == "\u{1}folder:deleteditems")
        // Gmail's identity mapping, which this must not be.
        #expect(vocabulary.label(for: .unread) != GmailVocabulary().label(for: .unread))
    }

    @Test("an account absent from the store does not resolve")
    func unknownAccountDoesNotResolve() {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        #expect(LabelVocabularyResolver.vocabulary(forAccountID: "ghost", store: store) == nil)
        #expect(LabelVocabularyResolver.vocabulary(forAccountID: nil, store: store) == nil)
    }

    /// The behaviour that makes the nil above safe: the UI reports the account
    /// as unactionable instead of enqueueing Gmail strings against it.
    @Test("the UI refuses an action on an unresolvable backend instead of guessing")
    func viewModelRefusesUnresolvableBackend() throws {
        let store = DocumentMailStore(documents: InMemoryDocumentStore())
        let outbox = Outbox(documents: InMemoryDocumentStore(), provider: FakeMailProvider())
        try store.saveAccount(MailAccount(id: "im1", provider: .imap,
                                          address: "i@example.test", displayName: "I",
                                          state: .ready))
        try store.upsertThread(MailThread(id: "t1", accountID: "im1", messages: [
            MailMessage(id: "m1", threadID: "t1", from: MailAddress(email: "b@example.test"),
                        subject: "Subject 1", date: Date(), labelIDs: ["INBOX"], snippet: "s")
        ]))

        let model = RavenViewModel(store: store, outbox: outbox)
        model.reload()
        model.archive(["t1"])

        // Nothing queued, and the row says why.
        #expect(outbox.pending().isEmpty)
        #expect(model.rowErrors["t1"] != nil)
        // And the stored thread is untouched — no half-applied local mutation.
        let stored = try #require(store.thread("t1"))
        #expect(stored.messages[0].labelIDs == ["INBOX"])
    }
}
