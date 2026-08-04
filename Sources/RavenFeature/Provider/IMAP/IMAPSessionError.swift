import Foundation

/// Why a command, or the whole connection, failed.
enum IMAPSessionError: Error, Equatable {
    /// A command was issued before `connect()`, or after the session was closed
    /// or failed. Never a suspended call: a dead session refuses immediately.
    case notConnected
    /// The session (or the transport under it) was closed while this command was
    /// in flight. Every waiter gets this rather than staying suspended.
    case closed
    /// A `NO` or `BAD` tagged completion. Carries the tag so a log can be
    /// correlated with the recorded wire bytes.
    case commandFailed(tag: String, status: IMAPCommandStatus, text: String)
    /// The server's greeting was not `* OK`, `* PREAUTH` or `* BYE`.
    case malformedGreeting(String)
    /// The server said `* BYE` instead of greeting us.
    case greetingRejected(String)
    /// The stream is no longer interpretable as IMAP: an unknown tag, a
    /// continuation request nobody asked for, an unknown completion status. There
    /// is no framing to re-synchronise to, so this always tears the connection
    /// down — see `IMAPLexer`'s note on why re-syncing is not possible.
    case protocolError(String)
    case malformedResponse(IMAPLexerError)
    case transportFailure(MailTransportError)
    /// An exclusive command (`IMAPCommand.isExclusive` — in practice
    /// `AUTHENTICATE`) needs the channel to itself, and it did not have it.
    ///
    /// - `exclusiveTag` is the exclusive command's tag when an ordinary command
    ///   was refused admission while it was in flight.
    /// - `exclusiveTag` is nil when the exclusive command itself was refused
    ///   because other commands were already in flight.
    ///
    /// Refusing is the only safe answer. A SASL exchange is driven by `+ `
    /// continuation requests that carry no tag and that the server sends only
    /// sometimes, so it cannot be attributed by the FIFO that literals use;
    /// exclusivity is what makes "the single in-flight command" an exact
    /// attribution rather than a guess.
    case channelReserved(exclusiveTag: String?)
}

extension IMAPSessionError {
    /// Classifies an arbitrary thrown error as a session error.
    ///
    /// The one place the mapping lives, so the read loop, `execute` and
    /// `startTLS` cannot disagree about what a `MailTransportError.closed`
    /// means. A transport close becomes `.closed` rather than
    /// `.transportFailure(.closed)` because a caller's only sensible reaction to
    /// either is the same, and two spellings of one condition invite a `switch`
    /// that handles only one.
    static func classifying(_ error: any Error) -> IMAPSessionError {
        switch error {
        case let error as IMAPSessionError: return error
        case let error as MailTransportError:
            return error == .closed ? .closed : .transportFailure(error)
        case let error as IMAPLexerError: return .malformedResponse(error)
        default: return .protocolError(String(describing: error))
        }
    }
}
