import Foundation

/// Reading capability lists and greetings out of a token line.
///
/// Split out of `IMAPSession` for size, and it splits cleanly because none of it
/// touches session state: a capability list is a pure function of the tokens it
/// was found in. The session keeps the *policy* (when the cache is invalidated,
/// when a re-read is mandatory); this file keeps the *parsing*.
enum IMAPCapabilityList {
    /// Capability names, uppercased. IMAP capability names are case-insensitive,
    /// so normalising here is what lets every caller do a plain `contains`
    /// instead of each inventing its own comparison.
    static func names(in tokens: [IMAPToken]) -> Set<String> {
        Set(tokens.compactMap { $0.stringValue?.uppercased() })
    }

    /// The contents of a `[CAPABILITY …]` response code, or nil when the line
    /// carries none. Nil and empty are deliberately different: nil means "the
    /// server did not tell us", empty would mean "the server supports nothing".
    ///
    /// Both an untagged `* OK [CAPABILITY …]` greeting and a tagged
    /// `A001 OK [CAPABILITY …]` completion are handled by this one function,
    /// because both are legitimate places for a server to publish the list and
    /// a client that reads only one of them will send `LOGIN` against a stale
    /// list.
    static func code(in tokens: [IMAPToken]) -> Set<String>? {
        guard let open = tokens.firstIndex(of: .bracketOpen),
              open + 1 < tokens.count,
              tokens[open + 1].stringValue?.uppercased() == "CAPABILITY" else { return nil }
        let close = tokens[open...].firstIndex(of: .bracketClose) ?? tokens.endIndex
        guard open + 2 <= close else { return [] }
        return names(in: Array(tokens[(open + 2)..<close]))
    }

    /// The list from an untagged `* CAPABILITY …` line, or nil if that is not
    /// what this line is.
    static func untagged(_ tokens: [IMAPToken]) -> Set<String>? {
        guard tokens.first?.stringValue?.uppercased() == "CAPABILITY" else { return nil }
        return names(in: Array(tokens.dropFirst()))
    }
}

/// The server's opening line.
struct IMAPGreeting: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        /// Not authenticated yet.
        case ok = "OK"
        /// Already authenticated by external means (e.g. a pre-authenticated
        /// tunnel). Task 9 must not send credentials in this state.
        case preauth = "PREAUTH"
        /// Refused before we said anything.
        case bye = "BYE"
    }

    let kind: Kind
    let text: String
    /// Capabilities carried in a `[CAPABILITY …]` response code on the greeting,
    /// if any. Empty means "not advertised yet", never "none".
    let capabilities: Set<String>

    /// Interprets the first untagged line of the connection. A `BYE` greeting and
    /// an uninterpretable greeting are both *failures*, not values: neither can be
    /// followed by a command, and returning them as greetings would let a caller
    /// keep talking to a server that already hung up.
    static func parse(_ response: IMAPUntaggedResponse) -> Result<IMAPGreeting, any Error> {
        guard let word = response.head, let kind = Kind(rawValue: word) else {
            return .failure(IMAPSessionError.malformedGreeting(response.text))
        }
        let text = IMAPResponseText.render(Array(response.tokens.dropFirst()))
        if kind == .bye { return .failure(IMAPSessionError.greetingRejected(text)) }
        return .success(IMAPGreeting(kind: kind, text: text,
                                     capabilities: IMAPCapabilityList.code(in: response.tokens) ?? []))
    }
}
