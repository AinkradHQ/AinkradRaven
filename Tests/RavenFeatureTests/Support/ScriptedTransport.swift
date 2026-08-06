import Foundation
@testable import RavenFeature

/// A `MailTransport` that answers from a script instead of a socket, so every
/// parser, command channel and state machine above the transport seam is a pure
/// unit test.
///
/// Three capabilities matter, and the tasks that depend on each are named so a
/// future edit knows what it would break:
///
/// 1. **Chunking (`ChunkPlan`).** A real socket delivers a response split at an
///    arbitrary byte boundary — mid-CRLF, mid-literal, mid-quoted-string. A
///    naive line-oriented parser passes only when fed whole lines, so the
///    double must be able to split anywhere. `Task 7`'s lexer is tested by
///    looping `.splitAt(i)` over EVERY split point of a fixture and asserting
///    the token stream is identical to the whole-buffer one.
/// 2. **Per-command answers (`respond(to:with:)`).** Responses can depend on
///    what the client just sent, which is what lets a state machine be driven
///    (`Task 8` pipelining, `Task 12` delta strategies) rather than merely
///    replayed.
/// 3. **A recorded upgrade point (`upgradePoint`).** `startTLS()` records how
///    many bytes had already been sent, so `Task 9` and `Task 15` can assert
///    that NO credential byte preceded the upgrade.
///
/// Reads never suspend indefinitely: an empty script throws
/// `MailTransportError.scriptExhausted` so a wrong expectation fails the test
/// instead of hanging the suite.
actor ScriptedTransport: MailTransport {
    /// How a scripted response is broken into `read()` results.
    enum ChunkPlan: Sendable, Equatable {
        /// One `read()` returns the whole response.
        case whole
        /// Fixed-size chunks; `.fixed(1)` is the byte-at-a-time worst case.
        case fixed(Int)
        /// Exactly two chunks, split at this byte offset. Offsets ≤ 0 or ≥ count
        /// collapse to `.whole`, so a caller can loop `0...count` without
        /// special-casing the ends.
        case splitAt(Int)
        /// Split at each of these ascending byte offsets.
        case boundaries([Int])
    }

    private struct Rule {
        let needle: String
        let response: Data
        let plan: ChunkPlan
        var isRepeatable: Bool
    }

    /// What `read()` does when the script is empty.
    enum IdleReadBehavior: Sendable, Equatable {
        /// Throw `scriptExhausted` (the default): a wrong expectation fails the
        /// test instead of hanging the suite.
        case throwScriptExhausted
        /// Suspend until bytes are scripted or the transport closes — what a real
        /// socket does. Required by `Task 8`: a session's read loop legitimately
        /// waits between commands, and a *suspended* read is the only way to
        /// test that closing mid-flight fails every waiter instead of leaking a
        /// continuation. Suspended reads are still bounded: `close()` fails all
        /// of them with `.closed`, so nothing can hang past teardown.
        case suspend
    }

    private var chunkPlan: ChunkPlan
    private var pending: [Data] = []
    private var rules: [Rule] = []
    /// Needles whose `send(_:)` fails with **nothing recorded** — see
    /// `failSend(containing:)`.
    private var failingSendNeedles: [String] = []
    private var connected = false
    private var closed = false
    private let idleReadBehavior: IdleReadBehavior
    /// Reads suspended on an empty script. Resumed by `enqueue`/a matched rule,
    /// or failed by `close()` — each continuation is removed from this array
    /// before it is resumed, so it can never be resumed twice.
    private var readWaiters: [CheckedContinuation<Data, any Error>] = []

    // MARK: Recording (assertions read these)

    /// Every `send(_:)` in order, exactly as the caller passed it.
    private(set) var sent: [Data] = []
    /// Number of times `startTLS()` succeeded.
    private(set) var startTLSCount = 0
    /// Total bytes sent before the FIRST `startTLS()`, or nil if no upgrade
    /// happened. Assert a credential appears nowhere in `sentBytes` before this.
    private(set) var upgradePoint: Int?
    /// Number of `send(_:)` calls before the first `startTLS()`.
    private(set) var upgradeSendIndex: Int?

    init(chunkPlan: ChunkPlan = .whole,
         idleReads: IdleReadBehavior = .throwScriptExhausted) {
        self.chunkPlan = chunkPlan
        self.idleReadBehavior = idleReads
    }

    // MARK: Scripting

    /// Queues bytes to be readable immediately (a greeting, or an unsolicited
    /// untagged response).
    func enqueue(_ data: Data, plan: ChunkPlan? = nil) {
        pending.append(contentsOf: Self.chunks(of: data, plan: plan ?? chunkPlan))
        deliverToWaiters()
    }

    func enqueue(_ text: String, plan: ChunkPlan? = nil) {
        enqueue(Data(text.utf8), plan: plan)
    }

    /// Answers with `data` the first time a sent payload contains `needle`.
    /// Rules are matched in the order they were added; each is consumed unless
    /// `repeatable`.
    func respond(to needle: String, with data: Data,
                 plan: ChunkPlan? = nil, repeatable: Bool = false) {
        rules.append(Rule(needle: needle, response: data,
                          plan: plan ?? chunkPlan, isRepeatable: repeatable))
    }

    func respond(to needle: String, with text: String,
                 plan: ChunkPlan? = nil, repeatable: Bool = false) {
        respond(to: needle, with: Data(text.utf8), plan: plan, repeatable: repeatable)
    }

    /// Makes any `send(_:)` whose payload contains `needle` throw
    /// `MailTransportError.closed` **before recording anything**, modelling a
    /// connection that died with zero bytes of that write on the wire.
    ///
    /// The "nothing recorded" part is the whole point: `sent` stays a truthful
    /// record of what a server would have seen, so a test can assert that the
    /// message data really did NOT cross the wire. A rule that recorded the
    /// payload and then threw would be modelling a *partial* write instead, which
    /// this seam cannot express (`send` either delivers the whole `Data` or
    /// throws) and which would make exactly that assertion unavailable.
    func failSend(containing needle: String) { failingSendNeedles.append(needle) }

    /// Re-chunks every response queued from now on.
    func setChunkPlan(_ plan: ChunkPlan) { chunkPlan = plan }

    // MARK: Recording accessors

    /// Everything the client sent, concatenated — the byte stream a server
    /// would have seen.
    var sentBytes: Data { sent.reduce(into: Data()) { $0.append($1) } }
    var sentText: String { String(decoding: sentBytes) }
    /// Bytes sent before the first `startTLS()`. Empty when no upgrade happened.
    var bytesSentBeforeUpgrade: Data {
        guard let upgradePoint else { return Data() }
        return Data(sentBytes.prefix(upgradePoint))
    }
    var isConnected: Bool { connected }
    var isClosed: Bool { closed }
    var unreadChunkCount: Int { pending.count }

    // MARK: - MailTransport

    func connect() async throws {
        if closed { throw MailTransportError.closed }
        connected = true
    }

    func send(_ bytes: Data) async throws {
        try requireOpen()
        let payload = String(decoding: bytes)
        if failingSendNeedles.contains(where: { payload.contains($0) }) {
            throw MailTransportError.closed
        }
        sent.append(bytes)
        for index in rules.indices {
            guard payload.contains(rules[index].needle) else { continue }
            let rule = rules[index]
            if !rule.isRepeatable { rules.remove(at: index) }
            pending.append(contentsOf: Self.chunks(of: rule.response, plan: rule.plan))
            deliverToWaiters()
            return
        }
    }

    func read() async throws -> Data {
        try requireOpen()
        if !pending.isEmpty { return pending.removeFirst() }
        switch idleReadBehavior {
        case .throwScriptExhausted:
            throw MailTransportError.scriptExhausted(
                "read() with an empty script; sent so far: \(sentText.debugDescription)")
        case .suspend:
            return try await withCheckedThrowingContinuation { continuation in
                // No await since `requireOpen()`, so a close cannot have slipped
                // in between the check and the registration.
                if closed {
                    continuation.resume(throwing: MailTransportError.closed)
                } else if !pending.isEmpty {
                    continuation.resume(returning: pending.removeFirst())
                } else {
                    readWaiters.append(continuation)
                }
            }
        }
    }

    /// Hands buffered chunks to suspended reads, oldest first.
    private func deliverToWaiters() {
        while !readWaiters.isEmpty, !pending.isEmpty {
            let waiter = readWaiters.removeFirst()
            waiter.resume(returning: pending.removeFirst())
        }
    }

    /// Suspended reads waiting on an empty script. Assertable so a test can prove
    /// a session's read loop really is parked before it closes the transport.
    var suspendedReadCount: Int { readWaiters.count }

    func startTLS() async throws {
        try requireOpen()
        if upgradePoint == nil {
            upgradePoint = sentBytes.count
            upgradeSendIndex = sent.count
        }
        startTLSCount += 1
    }

    func close() async {
        closed = true
        connected = false
        pending.removeAll()
        // Fail every suspended read rather than leaving it hanging — the same
        // contract `MailTransport.close()` states and `NetworkTransport` honours.
        let waiters = readWaiters
        readWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: MailTransportError.closed) }
    }

    private func requireOpen() throws {
        if closed { throw MailTransportError.closed }
        if !connected { throw MailTransportError.notConnected }
    }

    // MARK: - Chunking

    /// Splits `data` per `plan`. Always returns at least one chunk for non-empty
    /// data, never an empty chunk (an empty `read()` result would be
    /// indistinguishable from end-of-stream on a real socket).
    static func chunks(of data: Data, plan: ChunkPlan) -> [Data] {
        guard !data.isEmpty else { return [] }
        let bytes = [UInt8](data)
        let offsets: [Int]
        switch plan {
        case .whole:
            offsets = []
        case .fixed(let size):
            guard size > 0, size < bytes.count else { return [data] }
            offsets = Array(stride(from: size, to: bytes.count, by: size))
        case .splitAt(let offset):
            offsets = (offset > 0 && offset < bytes.count) ? [offset] : []
        case .boundaries(let raw):
            offsets = raw.filter { $0 > 0 && $0 < bytes.count }.sorted()
        }
        var result: [Data] = []
        var start = 0
        for offset in offsets where offset > start {
            result.append(Data(bytes[start..<offset]))
            start = offset
        }
        result.append(Data(bytes[start..<bytes.count]))
        return result
    }
}

private extension String {
    /// Lossy on purpose: recorded bytes are only ever used for assertions and
    /// failure messages, and a `nil` here would hide the actual payload.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
