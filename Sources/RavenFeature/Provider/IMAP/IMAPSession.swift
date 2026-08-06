import Foundation

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
        /// Chunks not yet written; each is written on one `+ ` request that this
        /// command's own literals GUARANTEED. Mirrored by `continuationOrder`.
        var remainingChunks: [Data]
        /// Written only if a `+ ` actually arrives. Never mirrored in
        /// `continuationOrder`, so that FIFO stays exact; attributable because a
        /// command carrying these is exclusive on the channel.
        var reactiveLines: [Data]
        var untagged: [IMAPUntaggedResponse] = []
        var waiter: CheckedContinuation<IMAPTaggedResponse, any Error>?
    }

    /// `private`, and it must stay that way. Every byte this actor writes goes
    /// through `execute` (and therefore `requireChannelAdmits` and a tag), and
    /// that is only structurally true while nothing outside this file can reach
    /// `transport.send`. An earlier version of the file split made this internal
    /// for `startTLS`'s benefit, which quietly turned "the one place every command
    /// passes through" back into a convention: any code in the module could do
    /// `await session.transport` and write raw untagged bytes. `performTLSHandshake`
    /// exposes the one operation the split genuinely needs instead.
    private let transport: any MailTransport
    private var state: State = .idle
    /// Not `private`: reset by `startTLS` in `IMAPSessionCapabilities.swift`.
    var lexer = IMAPLexer()
    /// Tokens of the response line being accumulated, minus its CRLF.
    /// Not `private`: reset by `startTLS` in `IMAPSessionCapabilities.swift`.
    var lineTokens: [IMAPToken] = []
    private var tagCounter = 0
    private var inFlight: [String: Record] = [:]
    /// Tags awaiting a `+ ` continuation request, in the order they were sent.
    /// IMAP servers answer continuations in command order, so FIFO is the only
    /// correct attribution available — a continuation request carries no tag.
    private var continuationOrder: [String] = []
    /// Results that arrived before their `execute` suspended. See rule 2 above.
    private var settledResults: [String: Result<IMAPTaggedResponse, any Error>] = [:]
    /// Tags whose caller was cancelled; the server still answers them. Cleared on
    /// `close()`/`teardown` — after either, nothing can arrive for them. See
    /// `abandon(tag:)`.
    private var abandonedTags: Set<String> = []
    /// Not `private`: owned by `IMAPSessionCapabilities.swift`.
    var capabilityCache: Set<String>?
    /// Untagged lines yielded to `untaggedResponses` so far. `IMAPIdleWatcher` reads
    /// it after its `SELECT` and skips that many stream elements, so the `* n EXISTS`
    /// a `SELECT` itself reports is never mistaken for an arrival notification.
    /// Incremented in the same isolated step as the yield, so the count and the
    /// stream cannot disagree.
    private(set) var untaggedYieldCount = 0
    /// Not `private`: owned by `IMAPSessionGreeting.swift`.
    var greetingResult: Result<IMAPGreeting, any Error>?
    /// Not `private`: owned by `IMAPSessionGreeting.swift`.
    var greetingWaiter: CheckedContinuation<IMAPGreeting, any Error>?
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
    /// Cancelled tags still awaiting the server's (now ignored) completion. Must be
    /// 0 after `close()`: nothing can arrive for them once the transport is gone,
    /// so a non-zero count there is a leak that grows with the session's lifetime.
    var abandonedTagCount: Int { abandonedTags.count }
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
        // Nothing can arrive for an abandoned tag after this, so the set is dead
        // weight. It only ever drains when the server answers, and a server that
        // never answers would otherwise leave entries for the session's lifetime.
        abandonedTags.removeAll()
        readLoop?.cancel()
        readLoop = nil
        await transport.close()
        untaggedContinuation.finish()
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
        try requireChannelAdmits(command)
        let tag = nextTag()
        let plan = command.wirePlan(
            tag: tag,
            allowNonSynchronizingLiterals: hasCapability("LITERAL+"))
        var remaining = plan.chunks
        let first = remaining.removeFirst()
        inFlight[tag] = Record(tag: tag, command: command, remainingChunks: remaining,
                               reactiveLines: command.reactiveContinuationLines)
        if !remaining.isEmpty { continuationOrder.append(tag) }
        do {
            try await transport.send(first)
        } catch {
            // Nothing reached the server (or only part did): drop the record so
            // no response can be routed to a caller that already threw, and
            // discard a result that raced in during the send.
            discardRecord(tag)
            throw IMAPSessionError.classifying(error)
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
        // Cancellation is the ONE path that is not a teardown, so it needs its own
        // handler: a cancelled caller would otherwise leave its record in
        // `inFlight` forever, and since `requireChannelAdmits` reads `inFlight`, a
        // stranded EXCLUSIVE record refuses every later command. See `abandon`.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let parked = settledResults.removeValue(forKey: tag) {
                    continuation.resume(with: parked)
                } else if inFlight[tag] == nil {
                    continuation.resume(throwing: IMAPSessionError.closed)
                } else {
                    inFlight[tag]?.waiter = continuation
                }
            }
        } onCancel: {
            // Not actor-isolated, so it hops. Correct in either order relative to
            // the continuation's registration: `settle` parks a result when no
            // waiter exists yet, and `execute` claims a parked result first.
            Task { await self.abandon(tag: tag) }
        }
    }

    /// Fails a cancelled command's waiter, drops its record (which is what frees
    /// an exclusive command's reservation) and remembers the tag.
    ///
    /// The tag must be remembered: IMAP cannot withdraw an issued command, so the
    /// server still answers it, and `handleTagged` treats a completion for an
    /// unknown tag as unrecoverable. Swallowing exactly what we abandoned is what
    /// stops one cancelled caller killing a shared connection.
    private func abandon(tag: String) async {
        guard inFlight[tag] != nil else { return }
        // An unwritten synchronising literal is the one case that cannot be clean:
        // the server awaits octets nobody will write and the `{n}` cannot be
        // withdrawn, so the stream is desynchronised whatever we do. Say so.
        if continuationOrder.contains(tag) {
            await teardown(.protocolError(
                "command \(tag) cancelled with an unwritten literal; the stream cannot be resynchronised"))
            return
        }
        settle(tag: tag, result: .failure(CancellationError()))
        abandonedTags.insert(tag)
    }

    /// The single transport operation reachable from outside this file: the TLS
    /// handshake, which `startTLS` in `IMAPSessionCapabilities.swift` performs
    /// after the protocol-level negotiation it owns. Deliberately not a getter for
    /// `transport` — see that property.
    func performTLSHandshake() async throws {
        try await transport.startTLS()
    }

    /// Writes IDLE's bare, untagged `DONE` — the one byte sequence in the protocol
    /// that cannot go through `execute`, because RFC 2177 gives it no tag and it is
    /// written minutes after the command it terminates. Refuses unless the sole
    /// in-flight command actually holds the channel open, so it can never
    /// desynchronise an ordinary command's stream.
    func sendIdleDone() async throws {
        guard let tag = soleReactiveTag(), inFlight[tag]?.command.holdsChannelOpen == true else {
            throw IMAPSessionError.protocolError("DONE with no IDLE in flight")
        }
        try await transport.send(Data("DONE\r\n".utf8))
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%04d", tagCounter)
    }

    /// Enforces `IMAPCommand.isExclusive` where every command passes through, so it
    /// is a property of the channel, not a rule callers must remember.
    private func requireChannelAdmits(_ command: IMAPCommand) throws {
        if command.isExclusive {
            guard inFlight.isEmpty else {
                throw IMAPSessionError.channelReserved(exclusiveTag: nil)
            }
        } else if let held = inFlight.values.first(where: { $0.command.isExclusive }) {
            throw IMAPSessionError.channelReserved(exclusiveTag: held.tag)
        }
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

    /// Not `private`: `startTLS` in `IMAPSessionCapabilities.swift` tears down on a
    /// failed handshake. Still actor isolated.
    func teardown(_ error: IMAPSessionError) async {
        switch state {
        case .closed: return
        default: break
        }
        state = .failed(error)
        failAllWaiters(error)
        abandonedTags.removeAll()
        await transport.close()
        untaggedContinuation.finish()
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
            await teardown(IMAPSessionError.classifying(error))
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
        untaggedYieldCount += 1
        // Attribution is only unambiguous with exactly one command in flight.
        if inFlight.count == 1, let onlyTag = inFlight.keys.first {
            inFlight[onlyTag]?.untagged.append(response)
        }
    }

    /// Answers a `+ `. Two attribution mechanisms, in priority order, neither
    /// guessing: (1) `continuationOrder`, the EXACT FIFO of tags that wrote a `{n}`
    /// and are GUARANTEED a `+ ` — nothing speculative is ever put there, which is
    /// what keeps it exact; (2) a reactive line from the single in-flight exclusive
    /// command — a SASL ack, sent only sometimes, so pre-registering it would make
    /// that FIFO an over-approximation. Anything else is a continuation nobody can
    /// own, with no framing to recover from, so it tears the connection down.
    private func handleContinuationRequest(_ tokens: [IMAPToken]) async throws {
        guard !continuationOrder.isEmpty else {
            if let tag = soleReactiveTag(), var record = inFlight[tag] {
                // IDLE: the `+ idling` IS the answer. Nothing is written until
                // `sendIdleDone()`, so absorbing it is correct rather than a
                // desynchronisation. See `IMAPCommand.holdsChannelOpen`.
                if record.command.holdsChannelOpen { return }
                if !record.reactiveLines.isEmpty {
                    let line = record.reactiveLines.removeFirst()
                    inFlight[tag] = record
                    try await transport.send(line)
                    return
                }
            }
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

    /// The tag of the only command in flight, or nil when there is more than one.
    ///
    /// The falsifiable guard on the reactive path is the caller's
    /// `!reactiveLines.isEmpty`. `count == 1` is NOT falsifiable — relaxing it
    /// leaves the suite green, because only an exclusive command can carry reactive
    /// lines (`IMAPCommand.init` precondition) and `requireChannelAdmits` keeps it
    /// alone, so "has reactive lines" already implies "is sole". Verified by
    /// mutation. An `isExclusive` re-check that sat beside it was equally
    /// unfalsifiable *and* pure duplication, so it is gone; `count == 1` stays as
    /// belt-and-braces — explicitly not a tested guarantee — because it is what
    /// makes "sole" true here rather than an inference about two other files.
    ///
    /// It has a second caller now — `sendIdleDone` and the `holdsChannelOpen`
    /// branch above — and there `count == 1` IS load-bearing: "the sole in-flight
    /// command is an IDLE" is exactly the condition under which a bare `DONE` is
    /// attributable to something.
    private func soleReactiveTag() -> String? {
        guard inFlight.count == 1 else { return nil }
        return inFlight.keys.first
    }

    private func handleTagged(tag: String, rest: [IMAPToken]) throws {
        guard inFlight[tag] != nil else {
            // A cancelled command's completion: expected, swallowed exactly once.
            if abandonedTags.remove(tag) != nil { return }
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

}
