import Testing
import Foundation
@testable import RavenFeature

/// The lexing/framing step every `IMAPFetchParser` suite needs, in one place.
///
/// Extracted when the FETCH tests split into `IMAPFetchParserTests` (the shapes a
/// well-formed server sends) and `IMAPFetchBodyStructureEdgeCaseTests` (the
/// position-dependent extension fields and the refusals) — the same split
/// `IMAPAuthTests`/`IMAPChannelExclusivityTests` made, so neither file drifts
/// toward the 500-line ceiling.
enum IMAPFetchWire {

    /// A fixture capture's bytes, byte-for-byte. Fixtures are CRLF-exact and the
    /// tree is marked `-text` in `.gitattributes`, so no newline translation is
    /// applied here either.
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: name, withExtension: "txt"),
            "fixture \(name).txt is not in the test bundle")
        return try Data(contentsOf: url)
    }

    /// Lexes a wire capture and splits it into untagged responses — exactly the
    /// values `IMAPSession` hands to this parser. Literal payloads are already
    /// carved out by the lexer, so splitting on `.endOfLine` cannot be fooled by
    /// a CRLF inside a literal.
    static func untaggedResponses(_ data: Data) throws -> [IMAPUntaggedResponse] {
        let tokens = try IMAPLexer.tokenize(data)
        var lines: [[IMAPToken]] = []
        var current: [IMAPToken] = []
        for token in tokens {
            if token == .endOfLine {
                if !current.isEmpty { lines.append(current) }
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.map { line in
            IMAPUntaggedResponse(tokens: line.first == .atom("*")
                ? Array(line.dropFirst()) : line)
        }
    }

    static func parsed(_ name: String) throws -> [IMAPFetchResponse] {
        try untaggedResponses(try fixture(name)).compactMap { try IMAPFetchParser.parse($0) }
    }

    /// One response from an inline wire string, for shapes that do not warrant
    /// their own recorded capture.
    static func parsedLine(_ wire: String) throws -> IMAPFetchResponse {
        let responses = try untaggedResponses(Data(wire.utf8))
        let response = try #require(responses.first)
        return try #require(try IMAPFetchParser.parse(response))
    }

    /// The first untagged response of an inline wire string, *unparsed* — for
    /// tests whose subject is that `IMAPFetchParser.parse` refuses it.
    static func line(_ wire: String) throws -> IMAPUntaggedResponse {
        try #require(try untaggedResponses(Data(wire.utf8)).first)
    }
}
