import Foundation

@testable import RavenFeature

/// Test-only: production feeds the lexer in chunks and never needs this.
extension IMAPLexer {
    /// Convenience for whole-buffer callers and for the reference side of the
    /// every-split-point test. Not used in production, where bytes always arrive
    /// in chunks.
    static func tokenize(
        _ data: Data,
        maxLiteralBytes: Int = IMAPLexer.defaultMaxLiteralBytes,
        maxUnterminatedBytes: Int = IMAPLexer.defaultMaxUnterminatedBytes
    )
        throws -> [IMAPToken]
    {
        var lexer = IMAPLexer(
            maxLiteralBytes: maxLiteralBytes,
            maxUnterminatedBytes: maxUnterminatedBytes)
        lexer.append(data)
        return try lexer.drainTokens()
    }
}
