import Foundation

/// A read-only `MailProvider` backed by a local import of Mail.app's own
/// `.emlx` store (via `AppleMailImporter`/`EmlxParser`/`LocalThreading`).
/// There is no remote mailbox behind this — no network, no delta stream, no
/// transport to send or mutate through — so every write path refuses,
/// gated by `capabilities`, exactly as `MailProviderRouter.writableProvider`
/// expects of any `.readOnly` conformer.
public final class AppleMailProvider: MailProvider, @unchecked Sendable {
    public let accountID: String
    public let capabilities: MailProviderCapabilities = .readOnly

    /// Built lazily on first use rather than in `init`: `AppleMailImporter`
    /// is `@MainActor` (it mirrors `SyncEngine`'s own actor-isolated progress
    /// state), but `AppleMailProvider` itself is not — every `MailProvider`
    /// conformer is plain `Sendable`, callable off the main actor — so
    /// constructing the importer has to happen from an `async` context that
    /// can hop, never from this `init`.
    private let providedImporter: AppleMailImporter?
    private let directory: URL
    /// The full imported+threaded state, cached after the first read so
    /// repeated calls (`fetchThread`, `fetchBody`, `searchThreads`) don't
    /// re-walk the directory. `nil` until `ensureImported()` runs once.
    private var cachedThreads: [MailThread]?

    public init(accountID: String, directory: URL, importer: AppleMailImporter? = nil) {
        self.accountID = accountID
        self.directory = directory
        self.providedImporter = importer
    }

    private func ensureImported() async throws -> [MailThread] {
        if let cachedThreads { return cachedThreads }
        let importer: AppleMailImporter
        if let providedImporter {
            importer = providedImporter
        } else {
            importer = await AppleMailImporter(accountID: accountID)
        }
        let threads = try await importer.importAll(from: directory)
        cachedThreads = threads
        return threads
    }

    // MARK: Read paths

    public func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
        let threads = try await ensureImported()
            .filter { $0.lastMessageDate >= since }
            .sorted { $0.lastMessageDate > $1.lastMessageDate }
        // One page, no further token: the whole local import is already in
        // memory once parsed, so there is nothing to page against a remote
        // server for — unlike Gmail, where a page is a real network request.
        return ThreadPage(threads: threads, nextPageToken: nil)
    }

    public func fetchThread(id: String) async throws -> MailThread {
        guard let thread = try await ensureImported().first(where: { $0.id == id }) else {
            throw MailError.unknownThread(id)
        }
        return thread
    }

    public func fetchBody(messageID: String) async throws -> MessageBody {
        for thread in try await ensureImported() {
            if let message = thread.messages.first(where: { $0.id == messageID }) {
                // The importer only ever populates `plainText`/`html` at
                // parse time and does not persist them onto `MailMessage`
                // (which carries no body field) — re-derive by re-parsing
                // is out of scope for M0 of this provider; the snippet
                // stands in until a dedicated body cache exists. Documented
                // here rather than silently returning an empty body.
                return MessageBody(messageID: messageID, plainText: message.snippet, html: nil)
            }
        }
        throw MailError.unknownThread(messageID)
    }

    public func fetchAttachment(messageID: String, attachmentID: String) async throws -> Data {
        // No attachment bytes are cached by the importer (see
        // `AppleMailImporter.mailMessage`, `hasAttachments: false`) — nothing
        // to serve yet.
        throw MailError.decodingFailed("attachment \(attachmentID)")
    }

    public func fetchLabels() async throws -> [MailLabel] { [] }

    public func fetchDelta(cursor: String) async throws -> MailDelta {
        // No remote change stream exists for a local import — everything
        // "changed" is whatever a fresh `importAll` finds, so a delta is
        // always empty and the cursor never moves.
        MailDelta(changedThreadIDs: [], removedThreadIDs: [], newCursor: cursor)
    }

    public func currentCursor() async throws -> String { "applemail-\(accountID)" }

    public func searchThreads(query: String, limit: Int) async throws -> [MailThread] {
        let lowered = query.lowercased()
        guard !lowered.isEmpty else { return [] }
        return try await ensureImported().filter { thread in
            thread.subject.lowercased().contains(lowered)
                || thread.messages.contains { $0.snippet.lowercased().contains(lowered) }
        }.prefix(limit).map { $0 }
    }

    // MARK: Mutations — refused, gated by `capabilities`

    public func applyLabels(_ mutation: LabelMutation) async throws {
        throw MailError.readOnlyAccount(accountID)
    }

    public func send(_ message: OutgoingMessage) async throws -> String {
        throw MailError.readOnlyAccount(accountID)
    }
}
