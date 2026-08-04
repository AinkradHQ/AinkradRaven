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

    private var chunkPlan: ChunkPlan
    private var pending: [Data] = []
    private var rules: [Rule] = []
    private var connected = false
    private var closed = false

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

    init(chunkPlan: ChunkPlan = .whole) {
        self.chunkPlan = chunkPlan
    }

    // MARK: Scripting

    /// Queues bytes to be readable immediately (a greeting, or an unsolicited
    /// untagged response).
    func enqueue(_ data: Data, plan: ChunkPlan? = nil) {
        pending.append(contentsOf: Self.chunks(of: data, plan: plan ?? chunkPlan))
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
        sent.append(bytes)
        let payload = String(decoding: bytes)
        for index in rules.indices {
            guard payload.contains(rules[index].needle) else { continue }
            let rule = rules[index]
            if !rule.isRepeatable { rules.remove(at: index) }
            pending.append(contentsOf: Self.chunks(of: rule.response, plan: rule.plan))
            return
        }
    }

    func read() async throws -> Data {
        try requireOpen()
        guard !pending.isEmpty else {
            throw MailTransportError.scriptExhausted(
                "read() with an empty script; sent so far: \(sentText.debugDescription)")
        }
        return pending.removeFirst()
    }

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
