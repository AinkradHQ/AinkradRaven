import Testing
import Foundation
@testable import RavenFeature

/// `VANISHED`'s `uid-set`, which arrives in two token shapes and whose failure
/// mode is silent under-reporting of deletions.
@Suite("IMAP sequence set")
struct IMAPSequenceSetTests {

    /// The tokens of a real `* VANISHED (EARLIER) …` line, so the shape under test
    /// is the lexer's output rather than a hand-built guess about it.
    private func vanishedTokens(_ set: String) throws -> [IMAPToken] {
        let line = try IMAPFetchWire.line("* VANISHED (EARLIER) \(set)\r\n")
        // Everything after the `VANISHED` keyword and its modifier list.
        return Array(line.tokens.dropFirst(4))
    }

    @Test("a single UID lexes as a number and is read")
    func singleUID() throws {
        #expect(try IMAPSequenceSet.uids(in: vanishedTokens("12")) == [12])
    }

    @Test("a coalesced set lexes as ONE atom and every UID in it is read")
    func coalescedSet() throws {
        // `:` and `,` are not delimiters in `IMAPLexer`, so this whole set is a
        // single `.atom`. A reader that only handled `.number` would return an
        // empty set here — deletions silently kept forever.
        let tokens = try vanishedTokens("11:13,20,31:32")
        #expect(tokens.count == 1)
        #expect(try IMAPSequenceSet.uids(in: tokens) == [11, 12, 13, 20, 31, 32])
    }

    @Test("a descending range means the same as its ascending form")
    func descendingRange() throws {
        #expect(try IMAPSequenceSet.uids(inText: "14:12") == [12, 13, 14])
    }

    @Test("a set naming * is refused rather than guessed")
    func starIsRefused() throws {
        // The refusal names the element it could not read (`*`), not the whole
        // set: that is the part a diagnostic needs.
        #expect(throws: IMAPDeltaError.unresolvableSequenceSet("*")) {
            try IMAPSequenceSet.uids(inText: "12:*")
        }
    }

    @Test("a range wider than the bound is refused rather than expanded")
    func tooWideIsRefused() throws {
        let wide = "1:\(IMAPSequenceSet.maxRangeWidth + 1)"
        #expect(throws: IMAPDeltaError.sequenceSetTooWide(wide)) {
            try IMAPSequenceSet.uids(inText: wide)
        }
        // The bound is inclusive of the widest allowed range, so the case just
        // below it still parses — otherwise "bounded" would be off by one and the
        // refusal would fire on legitimate input.
        let allowed = "1:\(IMAPSequenceSet.maxRangeWidth)"
        #expect(try IMAPSequenceSet.uids(inText: allowed).count
            == Int(IMAPSequenceSet.maxRangeWidth))
    }

    @Test("an empty or non-numeric set is refused, never read as no deletions")
    func garbageIsRefused() throws {
        #expect(throws: (any Error).self) { try IMAPSequenceSet.uids(inText: "") }
        #expect(throws: (any Error).self) { try IMAPSequenceSet.uids(inText: "EARLIER") }
    }

    @Test("a VANISHED line with no set at all is refused, not read as no deletions")
    func missingSetIsRefused() throws {
        // `* VANISHED (EARLIER)` and nothing more: every token is consumed as the
        // modifier list, so the token path is handed an EMPTY stream. Returning an
        // empty set there is indistinguishable from "nothing was deleted" — the
        // wrong answer that looks like a right one. The token entry point must
        // refuse it exactly as `uids(inText:)` refuses `""`.
        let line = try IMAPFetchWire.line("* VANISHED (EARLIER)\r\n")
        #expect(throws: (any Error).self) {
            try IMAPSequenceSet.uids(in: Array(line.tokens.dropFirst(4)))
        }
        #expect(throws: (any Error).self) { try IMAPSequenceSet.uids(in: []) }
    }
}
