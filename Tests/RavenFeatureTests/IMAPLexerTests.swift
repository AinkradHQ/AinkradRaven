import Testing
import Foundation
@testable import RavenFeature

@Suite("IMAP response lexer")
struct IMAPLexerTests {

    // MARK: - Fixtures

    /// Loads a redacted fixture out of the test bundle. `#require` here is also
    /// the check that `project.yml` really does build
    /// `Tests/RavenFeatureTests/Fixtures` as resources — a fixture that never
    /// reaches the bundle fails HERE, with a clear message, instead of as a
    /// confusing empty-token assertion later.
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: name, withExtension: "txt"),
            "fixture \(name).txt is not in the test bundle")
        return try Data(contentsOf: url)
    }

    /// Feeds `data` through `ScriptedTransport` with the given chunk plan and
    /// returns every token, i.e. exactly the path production takes: `read()` →
    /// `append` → `drainTokens`.
    private func tokensViaTransport(_ data: Data,
                                    plan: ScriptedTransport.ChunkPlan) async throws -> [IMAPToken] {
        let transport = ScriptedTransport(chunkPlan: plan)
        try await transport.connect()
        await transport.enqueue(data)
        var lexer = IMAPLexer()
        var tokens: [IMAPToken] = []
        while await transport.unreadChunkCount > 0 {
            lexer.append(try await transport.read())
            tokens.append(contentsOf: try lexer.drainTokens())
        }
        #expect(lexer.hasPartialToken == false,
                "the lexer retained a tail after a complete response")
        return tokens
    }

    // MARK: - Token kinds

    @Test("atoms, numbers, NIL and quoted strings with escapes")
    func scalarTokens() throws {
        let tokens = try IMAPLexer.tokenize(Data("* 12 FETCH NIL nil \"a b\" \"q\\\"x\\\\y\"\r\n".utf8))
        #expect(tokens == [
            .atom("*"), .number(12), .atom("FETCH"), .nilValue, .nilValue,
            .quoted("a b"), .quoted("q\"x\\y"), .endOfLine,
        ])
    }

    @Test("a quoted NIL stays a string, and an over-long digit run stays an atom")
    func numbersAndNilAreNotOverEager() throws {
        let tokens = try IMAPLexer.tokenize(Data("\"NIL\" 99999999999999999999 007 0\r\n".utf8))
        #expect(tokens == [
            .quoted("NIL"), .atom("99999999999999999999"), .atom("007"), .number(0), .endOfLine,
        ])
    }

    @Test("[...] response codes lex as bracket tokens, including BODY[…]")
    func responseCodes() throws {
        let tokens = try IMAPLexer.tokenize(Data("* OK [UNSEEN 12] BODY[1]\r\n".utf8))
        #expect(tokens == [
            .atom("*"), .atom("OK"), .bracketOpen, .atom("UNSEEN"), .number(12), .bracketClose,
            .atom("BODY"), .bracketOpen, .number(1), .bracketClose, .endOfLine,
        ])
    }

    @Test("parenthesised lists nest at least 5 deep")
    func deepNesting() throws {
        let tokens = try IMAPLexer.tokenize(try fixture("imap-lexer-basic"))
        var depth = 0
        var maxDepth = 0
        for token in tokens {
            if token == .listOpen { depth += 1; maxDepth = max(maxDepth, depth) }
            if token == .listClose { depth -= 1 }
            #expect(depth >= 0, "a ) closed a list that was never opened")
        }
        #expect(depth == 0, "unbalanced parentheses in the fixture's token stream")
        #expect(maxDepth >= 6, "fixture nests only \(maxDepth) deep")
    }

    @Test("the whole basic fixture lexes with no leftover bytes")
    func basicFixtureLexes() throws {
        var lexer = IMAPLexer()
        lexer.append(try fixture("imap-lexer-basic"))
        let tokens = try lexer.drainTokens()
        #expect(lexer.hasPartialToken == false)
        // Ten response lines in the fixture, so ten CRLF tokens.
        #expect(tokens.filter { $0 == .endOfLine }.count == 10)
    }

    // MARK: - Literals: the crux

    @Test("a literal containing CRLF, ), \" and { is NOT re-tokenised")
    func literalBytesAreOpaque() throws {
        let payload = "Line 1)\r\n\"x\" {9}\r\nLine 2\r\n"
        let tokens = try IMAPLexer.tokenize(try fixture("imap-lexer-literal"))
        // The first response line, token for token. If any payload byte had been
        // re-scanned, extra tokens (an endOfLine, a listClose, a quoted, a second
        // literal) would appear between the literal and the closing paren.
        #expect(Array(tokens.prefix(11)) == [
            .atom("*"), .number(1), .atom("FETCH"), .listOpen,
            .atom("BODY"), .bracketOpen, .atom("TEXT"), .bracketClose,
            .literal(Data(payload.utf8)), .listClose, .endOfLine,
        ])
        // And the payload is byte-identical, embedded braces and all.
        let literals = tokens.compactMap { token -> Data? in
            if case .literal(let data) = token { return data }
            return nil
        }
        #expect(literals.first == Data(payload.utf8))
        #expect(literals.first?.count == 26)
    }

    @Test("a {0} empty literal parses, and a literal at end-of-response parses")
    func emptyAndTrailingLiterals() throws {
        let tokens = try IMAPLexer.tokenize(try fixture("imap-lexer-literal"))
        let literals = tokens.compactMap { token -> Data? in
            if case .literal(let data) = token { return data }
            return nil
        }
        #expect(literals.count == 3)
        #expect(literals[1] == Data())                  // {0}
        #expect(literals[2] == Data("abc".utf8))        // last token before CRLF
        // The {0} literal is followed immediately by ) CRLF, and the trailing
        // literal by CRLF — proving neither swallowed nor duplicated framing.
        #expect(Array(tokens.suffix(12)) == [
            .literal(Data()), .listClose, .endOfLine,
            .atom("*"), .atom("OK"), .literal(Data("abc".utf8)), .endOfLine,
            .atom("a002"), .atom("OK"), .atom("FETCH"), .atom("completed"), .endOfLine,
        ])
    }

    // MARK: - Incremental correctness

    /// The property that matters: chunking is invisible. Asserted at EVERY split
    /// point of each fixture (`ChunkPlan.splitAt(i)` for i in 0...count) plus the
    /// byte-at-a-time worst case, against the whole-buffer token stream as the
    /// reference. A boundary landing mid-CRLF, mid-literal-header, mid-literal
    /// payload, mid-quoted-string or mid-escape is therefore covered by
    /// construction rather than by hand-picked cases.
    @Test("fed at every split point, the token stream is identical to whole-buffer",
          arguments: ["imap-lexer-basic", "imap-lexer-literal"])
    func everySplitPointAgrees(name: String) async throws {
        let data = try fixture(name)
        let reference = try await tokensViaTransport(data, plan: .whole)
        #expect(reference.isEmpty == false)
        for offset in 0...data.count {
            let split = try await tokensViaTransport(data, plan: .splitAt(offset))
            #expect(split == reference, "split at \(offset) of \(name) diverged")
        }
    }

    @Test("fed one byte at a time, the token stream is identical to whole-buffer",
          arguments: ["imap-lexer-basic", "imap-lexer-literal"])
    func byteAtATimeAgrees(name: String) async throws {
        let data = try fixture(name)
        let reference = try await tokensViaTransport(data, plan: .whole)
        let drip = try await tokensViaTransport(data, plan: .fixed(1))
        #expect(drip == reference)
    }

    // MARK: - Bounds and malformed input

    @Test("a {999999999} literal is refused against the size cap, not allocated")
    func literalSizeCapRefusesHugeLiteral() throws {
        var lexer = IMAPLexer()
        lexer.append(Data("* 1 FETCH (BODY[TEXT] {999999999}\r\n".utf8))
        #expect(throws: IMAPLexerError.literalTooLarge(
            declared: 999_999_999, cap: IMAPLexer.defaultMaxLiteralBytes)) {
            _ = try lexer.drainTokens()
        }
    }

    @Test("the cap is enforced on the declared length, so no payload is buffered")
    func capAppliesBeforePayload() throws {
        var lexer = IMAPLexer(maxLiteralBytes: 4)
        lexer.append(Data("* OK {5}\r\nabcde\r\n".utf8))
        #expect(throws: IMAPLexerError.literalTooLarge(declared: 5, cap: 4)) {
            _ = try lexer.drainTokens()
        }
        // A literal exactly at the cap is allowed — the boundary is inclusive.
        var atCap = IMAPLexer(maxLiteralBytes: 5)
        atCap.append(Data("* OK {5}\r\nabcde\r\n".utf8))
        #expect(try atCap.drainTokens() == [
            .atom("*"), .atom("OK"), .literal(Data("abcde".utf8)), .endOfLine,
        ])
    }

    @Test("an endless unterminated line is refused rather than buffered forever")
    func unterminatedLineIsBounded() throws {
        var lexer = IMAPLexer(maxUnterminatedBytes: 32)
        lexer.append(Data(String(repeating: "A", count: 64).utf8))
        #expect(throws: IMAPLexerError.unterminatedTokenTooLong(cap: 32)) {
            _ = try lexer.drainTokens()
        }
    }

    @Test("an unterminated quoted string is bounded too")
    func unterminatedQuotedStringIsBounded() throws {
        var lexer = IMAPLexer(maxUnterminatedBytes: 16)
        lexer.append(Data(("\"" + String(repeating: "b", count: 40)).utf8))
        #expect(throws: IMAPLexerError.unterminatedTokenTooLong(cap: 16)) {
            _ = try lexer.drainTokens()
        }
    }

    @Test("a partial response yields no tokens and does not throw or hang")
    func partialInputWaits() throws {
        var lexer = IMAPLexer()
        lexer.append(Data("* OK [CAPAB".utf8))
        #expect(try lexer.drainTokens() == [.atom("*"), .atom("OK"), .bracketOpen])
        #expect(lexer.hasPartialToken)
        lexer.append(Data("ILITY]\r\n".utf8))
        #expect(try lexer.drainTokens() == [.atom("CAPABILITY"), .bracketClose, .endOfLine])
        #expect(lexer.hasPartialToken == false)
    }

    @Test("malformed input yields a typed error", arguments: [
        ("* OK \"bad \\x escape\"\r\n", IMAPLexerError.malformedQuotedString("illegal escape \\x")),
        ("* OK \"unclosed\rrest\"\r\n", IMAPLexerError.malformedQuotedString("CR or LF inside a quoted string")),
        ("* OK\ra001 OK\r\n", IMAPLexerError.malformedLineEnding),
        ("* OK\na001 OK\r\n", IMAPLexerError.malformedLineEnding),
        ("* OK {abc}\r\nx\r\n", IMAPLexerError.malformedLiteralHeader("unexpected byte in {…}: 97")),
        ("* OK {}\r\nx\r\n", IMAPLexerError.malformedLiteralHeader("empty or unparseable literal length")),
        ("* OK {3} abc\r\n", IMAPLexerError.malformedLiteralHeader("{n} not followed by CRLF")),
    ])
    func malformedInputThrowsTypedError(input: String, expected: IMAPLexerError) throws {
        var lexer = IMAPLexer()
        lexer.append(Data(input.utf8))
        var thrown: IMAPLexerError?
        do {
            _ = try lexer.drainTokens()
        } catch let error as IMAPLexerError {
            thrown = error
        }
        #expect(thrown == expected)
    }

    @Test("a malformed stream stays failed rather than pretending to resync")
    func failureIsSticky() throws {
        var lexer = IMAPLexer()
        lexer.append(Data("* OK \"bad \\x\"\r\n".utf8))
        #expect(throws: IMAPLexerError.self) { _ = try lexer.drainTokens() }
        lexer.append(Data("a001 OK done\r\n".utf8))
        #expect(throws: IMAPLexerError.self) { _ = try lexer.drainTokens() }
    }

    // MARK: - Redaction

    @Test("fixtures are redacted", arguments: ["imap-lexer-basic", "imap-lexer-literal"])
    func fixturesAreRedacted(name: String) throws {
        let text = try #require(String(data: try fixture(name), encoding: .utf8))
        for address in text.split(whereSeparator: { " <>\"()".contains($0) })
            where address.contains("@") {
            #expect(address.hasSuffix("example.test>") || address.hasSuffix("example.test"),
                    "non-redacted address \(address) in \(name)")
        }
    }
}
