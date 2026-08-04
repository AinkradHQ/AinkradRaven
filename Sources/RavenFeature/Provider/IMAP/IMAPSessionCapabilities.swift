import Foundation

/// `IMAPSession`'s capability cache and the two negotiation points that must
/// invalidate it.
///
/// Split out of `IMAPSession.swift` to keep it under the repo's 500-line limit,
/// and it splits along a real seam: everything here is *policy about the cache*
/// (when it is discarded, when a re-read is mandatory), whereas the main file is
/// the command channel. `IMAPCapabilities.swift` already holds the parsing.
///
/// ## What the split costs
///
/// Swift's `private` is file-scoped, so SIX of `IMAPSession`'s members had to
/// become internal for this file: `lexer`, `lineTokens`, `capabilityCache`,
/// `teardown`, and both `absorbCapabilities` overloads. Each is annotated at its
/// declaration. They are all still actor isolated, so the concurrency guarantee is
/// untouched; only file-level hiding within this one module is given up.
///
/// `transport` is deliberately NOT among them. It stayed `private` and this file
/// reaches the handshake through `performTLSHandshake()`, because an internal
/// `transport` would let any code in the module write raw untagged bytes and
/// bypass `requireChannelAdmits` entirely — see that property's documentation.
extension IMAPSession {

    // MARK: - CAPABILITY

    /// The advertised capability list, asking the server only if it is unknown.
    func capabilities() async throws -> Set<String> {
        if let capabilityCache { return capabilityCache }
        return try await reloadCapabilities()
    }

    /// Discards the cache and issues `CAPABILITY`.
    @discardableResult
    func reloadCapabilities() async throws -> Set<String> {
        capabilityCache = nil
        let response = try await execute(IMAPCommand("CAPABILITY"))
        if let capabilityCache { return capabilityCache }
        // Some servers answer only with a `[CAPABILITY …]` code on the tagged OK.
        if let coded = IMAPCapabilityList.code(in: response.tokens) {
            capabilityCache = coded
            return coded
        }
        throw IMAPSessionError.protocolError("CAPABILITY completed without a capability list")
    }

    func hasCapability(_ name: String) -> Bool {
        capabilityCache?.contains(name.uppercased()) ?? false
    }

    /// Negotiates `STARTTLS`, performs the handshake, then re-reads CAPABILITY.
    ///
    /// The re-read is mandatory, not an optimisation: RFC 3501 requires the
    /// client to discard the pre-TLS list (a man in the middle could have
    /// authored it) and servers legitimately advertise different capabilities —
    /// `LOGINDISABLED` disappears, `AUTH=` mechanisms appear — once TLS is up.
    /// Task 9's `LOGINDISABLED` check would be reading a stripped list otherwise.
    func startTLS() async throws {
        try await execute(IMAPCommand("STARTTLS"))
        do {
            // Not `transport.startTLS()`: the transport itself stays `private` to
            // `IMAPSession.swift` so nothing outside it can reach `send`. See
            // `performTLSHandshake`.
            try await performTLSHandshake()
        } catch let error as MailTransportError {
            let mapped = IMAPSessionError.transportFailure(error)
            await teardown(mapped)
            throw mapped
        }
        // The pre-TLS byte stream is finished; nothing buffered from it may be
        // interpreted as part of the encrypted one.
        lexer = IMAPLexer()
        lineTokens = []
        try await reloadCapabilities()
    }

    /// Call after any successful authentication. Servers routinely change the
    /// list at that point (`AUTH=` mechanisms go away, `IDLE`/`QUOTA`/namespace
    /// capabilities appear), and Task 11/12 branch on those.
    @discardableResult
    func capabilitiesAfterAuthentication() async throws -> Set<String> {
        try await reloadCapabilities()
    }

    /// Learns capabilities from `* CAPABILITY …` and from a `[CAPABILITY …]`
    /// response code, wherever either appears.
    ///
    /// Not `private`: the read loop in `IMAPSession.swift` calls it on every
    /// response line. Still actor isolated.
    func absorbCapabilities(from tokens: [IMAPToken]) {
        if let advertised = IMAPCapabilityList.untagged(tokens) {
            capabilityCache = advertised
            return
        }
        absorbCapabilities(fromResponseCodeIn: tokens)
    }

    /// Not `private`: called by `handleTagged` in `IMAPSession.swift` for the
    /// `[CAPABILITY …]` code on a tagged `OK`. Still actor isolated.
    func absorbCapabilities(fromResponseCodeIn tokens: [IMAPToken]) {
        if let coded = IMAPCapabilityList.code(in: tokens) { capabilityCache = coded }
    }
}
