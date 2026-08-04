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
}

/// The IMAP command channel: one actor owning one transport, issuing tagged
/// commands, and routing every response line to whoever is waiting for it.
///
/// ## Why an actor, and what it serialises
///
/// Two things mutate the in-flight table: the caller-side `execute`, and the
/// single read loop that consumes the socket. The actor is the only thing that
/// keeps those two from interleaving mid-update, which is why neither path takes
/// a lock and why the table can be a plain dictionary.
///
/// ## Continuation discipline (the bug class this file exists to avoid)
///
/// A command that never resumes hangs the sync engine forever and is
/// indistinguishable from a network stall. Three rules, all enforced here:
///
/// 1. **Resolution goes through `settle(tag:result:)` and nowhere else.** It
///    removes the record from `inFlight` *before* resuming, so a second
///    resolution for the same tag finds nothing and is a no-op. That is what
///    makes a double-resume impossible even if a broken server sends two tagged
///    completions for one tag.
/// 2. **A result that arrives before its waiter suspends is parked, not
///    dropped.** `execute` awaits `transport.send` before it suspends on the
///    continuation, and the read loop can complete the command during that
///    await. The result lands in `settledResults` and `execute` picks it up
///    without ever suspending. Without this the fast-server case would hang.
/// 3. **Every teardown path fails every waiter.** `close()`, a throwing
///    `transport.read()`, a peer close, and a protocol error all funnel into
///    `teardown(_:)` → `failAllWaiters(_:)`. `inFlightCount` is 0 afterwards,
///    which is what `IMAPSessionTests` asserts.
///
/// The literal drip is driven by the *read loop*, not by `execute`, so a command
/// only ever has one suspension point (its completion). Nesting "wait for `+`"
/// inside "wait for the tagged completion" would need two live continuations per
/// command, which is exactly how the leak in the OAuth code happened.
actor IMAPSession {
    private enum State {
        case idle
        case running
        case failed(IMAPSessionError)
        case closed
    }

    /// One in-flight command. A struct, not a class: it is only ever reached
    /// through `inFlight[tag]` under actor isolation, so there is no aliasing to
    /// reason about.
    private struct Record {
        let tag: String
        let command: IMAPCommand
        /// Chunks not yet written; each is written on one `+ ` request.
        var remainingChunks: [Data]
        var untagged: [IMAPUntaggedResponse] = []
        var waiter: CheckedContinuation<IMAPTaggedResponse, any Error>?
    }

    private let transport: any MailTransport
    private var state: State = .idle
    private var lexer = IMAPLexer()
    /// Tokens of the response line being accumulated, minus its CRLF.
    private var lineTokens: [IMAPToken] = []
    private var tagCounter = 0
    private var inFlight: [String: Record] = [:]
    /// Tags awaiting a `+ ` continuation request, in the order they were sent.
    /// IMAP servers answer continuations in command order, so FIFO is the only
    /// correct attribution available — a continuation request carries no tag.
    private var continuationOrder: [String] = []
    /// Results that arrived before their `execute` suspended. See rule 2 above.
    private var settledResults: [String: Result<IMAPTaggedResponse, any Error>] = [:]
    private var capabilityCache: Set<String>?
    private var greetingResult: Result<IMAPGreeting, any Error>?
    private var greetingWaiter: CheckedContinuation<IMAPGreeting, any Error>?
    private var readLoop: Task<Void, Never>?
    private let untaggedContinuation: AsyncStream<IMAPUntaggedResponse>.Continuation

    /// Every untagged response the server sends, in arrival order — including
    /// ones also attributed to a command. Unsolicited `* EXISTS` / `* EXPUNGE` /
    /// `* FETCH` (Task 14's IDLE) are read from here. Buffered rather than
    /// unbounded so a consumer that stops reading cannot grow memory forever.
    nonisolated let untaggedResponses: AsyncStream<IMAPUntaggedResponse>

    init(transport: any MailTransport) {
        self.transport = transport
        var continuation: AsyncStream<IMAPUntaggedResponse>.Continuation!
        self.untaggedResponses = AsyncStream(bufferingPolicy: .bufferingNewest(512)) {
            continuation = $0
        }
        self.untaggedContinuation = continuation
    }

    /// Only finishes the untagged stream. It deliberately does NOT try to resume
    /// waiters: a suspended `execute` holds a strong reference to this actor, so
    /// `deinit` cannot run while any waiter exists.
    deinit { untaggedContinuation.finish() }

    // MARK: - Introspection (assertions read these)

    /// Commands whose completion has neither arrived nor been handed to a waiter.
    /// Must be 0 after `close()`.
    var inFlightCount: Int { inFlight.count }
    var pendingContinuationTags: [String] { continuationOrder }
    /// The cached capability list, or nil when none has been learned yet. Nil is
    /// distinct from empty: it means "must ask", not "server supports nothing".
    var cachedCapabilities: Set<String>? { capabilityCache }
    var isRunning: Bool { if case .running = state { return true }; return false }

    // MARK: - Lifecycle

    /// Connects, starts the read loop, and returns the greeting.
    @discardableResult
    func connect() async throws -> IMAPGreeting {
        guard case .idle = state else { throw IMAPSessionError.notConnected }
        do {
            try await transport.connect()
        } catch let error as MailTransportError {
            state = .failed(.transportFailure(error))
            throw IMAPSessionError.transportFailure(error)
        }
        state = .running
        readLoop = Task { [weak self] in await self?.runReadLoop() }
        return try await waitForGreeting()
    }

    /// Idempotent. Fails every waiter with `.closed` and closes the transport.
    func close() async {
        switch state {
        case .closed: return
        default: break
        }
        state = .closed
        failAllWaiters(.closed)
        readLoop?.cancel()
        readLoop = nil
        await transport.close()
        untaggedContinuation.finish()
    }

    private func waitForGreeting() async throws -> IMAPGreeting {
        if let greetingResult { return try greetingResult.get() }
        return try await withCheckedThrowingContinuation { continuation in
            // No await between the check above and here, so no result can slip
            // in unobserved.
            if let greetingResult {
                continuation.resume(with: greetingResult)
            } else {
                greetingWaiter = continuation
            }
        }
    }

    private func settleGreeting(_ result: Result<IMAPGreeting, any Error>) {
        guard greetingResult == nil else { return }
        greetingResult = result
        if let waiter = greetingWaiter {
            greetingWaiter = nil
            waiter.resume(with: result)
        }
    }

    // MARK: - Issuing commands

    /// Sends `command` and returns its tagged completion. Safe to call
    /// concurrently: commands are pipelined and each response is routed by tag,
    /// so an out-of-order server answers every caller correctly.
    ///
    /// Untagged lines are attributed to a command only when it is the *only*
    /// command in flight; with two or more, attribution would be a guess, so they
    /// go to `untaggedResponses` alone. Callers that need attributed untagged
    /// data (FETCH) must therefore not pipeline that command — which matches how
    /// IMAP works, since untagged responses genuinely carry no tag.
    @discardableResult
    func execute(_ command: IMAPCommand) async throws -> IMAPTaggedResponse {
        try requireRunning()
        let tag = nextTag()
        let plan = command.wirePlan(
            tag: tag,
            allowNonSynchronizingLiterals: hasCapability("LITERAL+"))
        var remaining = plan.chunks
        let first = remaining.removeFirst()
        inFlight[tag] = Record(tag: tag, command: command, remainingChunks: remaining)
        if !remaining.isEmpty { continuationOrder.append(tag) }
        do {
            try await transport.send(first)
        } catch {
            // Nothing reached the server (or only part did): drop the record so
            // no response can be routed to a caller that already threw, and
            // discard a result that raced in during the send.
            discardRecord(tag)
            throw Self.mapped(error)
        }
        if let parked = settledResults.removeValue(forKey: tag) {
            return try parked.get()
        }
        // The command may have been failed while `send` was suspended.
        if inFlight[tag] == nil {
            if case .failed(let error) = state { throw error }
            if case .closed = state { throw IMAPSessionError.closed }
            throw IMAPSessionError.closed
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let parked = settledResults.removeValue(forKey: tag) {
                continuation.resume(with: parked)
            } else if inFlight[tag] == nil {
                continuation.resume(throwing: IMAPSessionError.closed)
            } else {
                inFlight[tag]?.waiter = continuation
            }
        }
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%04d", tagCounter)
    }

    private func requireRunning() throws {
        switch state {
        case .running: return
        case .failed(let error): throw error
        case .idle, .closed: throw IMAPSessionError.notConnected
        }
    }

    /// The single resolution point. Removing before resuming is what makes a
    /// double-resume impossible.
    private func settle(tag: String, result: Result<IMAPTaggedResponse, any Error>) {
        continuationOrder.removeAll { $0 == tag }
        guard var record = inFlight.removeValue(forKey: tag) else { return }
        if let waiter = record.waiter {
            record.waiter = nil
            waiter.resume(with: result)
        } else {
            settledResults[tag] = result
        }
    }

    private func discardRecord(_ tag: String) {
        inFlight.removeValue(forKey: tag)
        settledResults.removeValue(forKey: tag)
        continuationOrder.removeAll { $0 == tag }
    }

    private func failAllWaiters(_ error: IMAPSessionError) {
        settleGreeting(.failure(error))
        for tag in inFlight.keys { settle(tag: tag, result: .failure(error)) }
        // Anything parked was already resolved for its caller; a parked result
        // whose caller never returns cannot happen, because `execute` only
        // suspends after the park is checked.
    }

    private func teardown(_ error: IMAPSessionError) async {
        switch state {
        case .closed: return
        default: break
        }
        state = .failed(error)
        failAllWaiters(error)
        await transport.close()
        untaggedContinuation.finish()
    }

    private static func mapped(_ error: any Error) -> IMAPSessionError {
        switch error {
        case let error as IMAPSessionError: return error
        case let error as MailTransportError:
            return error == .closed ? .closed : .transportFailure(error)
        case let error as IMAPLexerError: return .malformedResponse(error)
        default: return .protocolError(String(describing: error))
        }
    }

    // MARK: - Read loop

    /// The one consumer of `transport.read()`. If it exits for ANY reason —
    /// close, peer hang-up, malformed bytes, an unknown tag — it fails every
    /// waiter on the way out. A read loop that merely stopped would leave the
    /// whole session suspended forever.
    private func runReadLoop() async {
        do {
            while true {
                if Task.isCancelled { throw IMAPSessionError.closed }
                let data = try await transport.read()
                lexer.append(data)
                for token in try lexer.drainTokens() {
                    if case .endOfLine = token {
                        let tokens = lineTokens
                        lineTokens = []
                        try await handle(line: tokens)
                    } else {
                        lineTokens.append(token)
                    }
                }
            }
        } catch {
            await teardown(Self.mapped(error))
        }
    }

    private func handle(line tokens: [IMAPToken]) async throws {
        guard let lead = tokens.first?.stringValue else {
            guard tokens.isEmpty else {
                throw IMAPSessionError.protocolError("response line starts with a structural token")
            }
            return // a bare CRLF: ignore rather than tear down
        }
        switch lead {
        case "*":
            handleUntagged(Array(tokens.dropFirst()))
        case "+":
            try await handleContinuationRequest(Array(tokens.dropFirst()))
        default:
            try handleTagged(tag: lead, rest: Array(tokens.dropFirst()))
        }
    }

    private func handleUntagged(_ tokens: [IMAPToken]) {
        let response = IMAPUntaggedResponse(tokens: tokens)
        absorbCapabilities(from: tokens)
        if greetingResult == nil {
            settleGreeting(IMAPGreeting.parse(response))
            return
        }
        untaggedContinuation.yield(response)
        // Attribution is only unambiguous with exactly one command in flight.
        if inFlight.count == 1, let onlyTag = inFlight.keys.first {
            inFlight[onlyTag]?.untagged.append(response)
        }
    }

    private func handleContinuationRequest(_ tokens: [IMAPToken]) async throws {
        guard !continuationOrder.isEmpty else {
            throw IMAPSessionError.protocolError(
                "continuation request with no command awaiting one: \(IMAPResponseText.render(tokens))")
        }
        let tag = continuationOrder[0]
        guard var record = inFlight[tag], !record.remainingChunks.isEmpty else {
            // The command is gone (failed/closed) — the FIFO entry is stale.
            continuationOrder.removeFirst()
            return
        }
        let chunk = record.remainingChunks.removeFirst()
        if record.remainingChunks.isEmpty { continuationOrder.removeFirst() }
        inFlight[tag] = record
        try await transport.send(chunk)
    }

    private func handleTagged(tag: String, rest: [IMAPToken]) throws {
        guard inFlight[tag] != nil else {
            throw IMAPSessionError.protocolError("completion for unknown tag \(tag)")
        }
        guard let statusWord = rest.first?.stringValue,
              let status = IMAPCommandStatus(rawValue: statusWord.uppercased()) else {
            throw IMAPSessionError.protocolError(
                "completion for \(tag) with no OK/NO/BAD: \(IMAPResponseText.render(rest))")
        }
        let remainder = Array(rest.dropFirst())
        if status == .ok { absorbCapabilities(fromResponseCodeIn: remainder) }
        let response = IMAPTaggedResponse(
            tag: tag,
            status: status,
            text: IMAPResponseText.render(remainder),
            tokens: remainder,
            untagged: inFlight[tag]?.untagged ?? [])
        if status == .ok {
            settle(tag: tag, result: .success(response))
        } else {
            // A NO/BAD is this command's failure and nobody else's: the other
            // in-flight commands keep running.
            settle(tag: tag, result: .failure(IMAPSessionError.commandFailed(
                tag: tag, status: status, text: response.text)))
        }
    }

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
            try await transport.startTLS()
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
    private func absorbCapabilities(from tokens: [IMAPToken]) {
        if let advertised = IMAPCapabilityList.untagged(tokens) {
            capabilityCache = advertised
            return
        }
        absorbCapabilities(fromResponseCodeIn: tokens)
    }

    private func absorbCapabilities(fromResponseCodeIn tokens: [IMAPToken]) {
        if let coded = IMAPCapabilityList.code(in: tokens) { capabilityCache = coded }
    }

}
