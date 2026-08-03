import Foundation

/// Walks a directory of `.emlx` files, parses and threads them, and hands
/// back `MailThread`s in pages — the read-only counterpart to
/// `SyncEngine.backfill()`'s page walk.
///
/// Progress is reported through the SAME shape `SyncEngine` already uses
/// (`SyncState` + an `onChange` callback fired on this class's own
/// `@MainActor`) rather than a new channel, so any UI already wired to a
/// `SyncEngine` (the Accounts surface) can observe an Apple Mail import
/// identically.
///
/// File I/O and MIME/`.emlx` parsing happen off the main actor (in the
/// `Task.detached`-free `parseBatch` below, called from a background
/// `Task` the caller owns) — this type itself only coordinates: listing
/// files, batching, checking cancellation, and publishing progress.
@MainActor public final class AppleMailImporter {
    /// How many `.emlx` files are parsed per page — bounds one batch's
    /// pause point so `Task.isCancelled` is checked frequently rather than
    /// only once per (potentially huge) mailbox.
    public static let pageSize = 200

    public private(set) var state: SyncState = .idle {
        didSet { onChange?() }
    }
    /// Same convention as `SyncEngine.onChange`: synchronous, on this
    /// class's own actor, `nil` until wired.
    public var onChange: (() -> Void)?

    private let accountID: String
    private let fileManager: FileManager

    public init(accountID: String, fileManager: FileManager = .default) {
        self.accountID = accountID
        self.fileManager = fileManager
    }

    /// Recursively lists every `.emlx` file under `directory` (Mail.app nests
    /// them several levels deep under per-mailbox folders), then imports them
    /// page by page, threading the whole batch via `LocalThreading` once
    /// everything is parsed — threading needs the full `References` graph, so
    /// it cannot be decided per-page.
    ///
    /// Cancellable: checked at the top of every page. A caller that cancels
    /// its own `Task` mid-walk gets back whatever pages had already
    /// completed, not a rollback — matching `SyncEngine.backfill()`'s own
    /// "a partial pass is still real progress" contract, and idempotent for
    /// the same reason `upsertThread` is: re-running the walk from scratch
    /// just re-parses the same files.
    public func importAll(from directory: URL) async throws -> [MailThread] {
        state = .backfilling(threadsSynced: 0)
        let files = try listEmlxFiles(directory)
        var parsed: [(EmlxMessage, path: URL)] = []
        var index = 0
        while index < files.count {
            try Task.checkCancellation()
            let end = min(index + Self.pageSize, files.count)
            let batch = Array(files[index..<end])
            let results = try await parseBatch(batch)
            parsed.append(contentsOf: results)
            index = end
            state = .backfilling(threadsSynced: parsed.count)
        }
        try Task.checkCancellation()
        state = .idle
        return thread(parsed.map(\.0))
    }

    private func listEmlxFiles(_ directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [URL] = []
        for entry in enumerator {
            guard let url = entry as? URL, url.pathExtension == "emlx" else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Parses one page off the main actor. A file that fails to read or
    /// parse is skipped — never aborts the batch — per `EmlxParser`'s own
    /// contract.
    private func parseBatch(_ paths: [URL]) async throws -> [(EmlxMessage, path: URL)] {
        try Task.checkCancellation()
        return await Task.detached(priority: .utility) {
            var results: [(EmlxMessage, path: URL)] = []
            for path in paths {
                guard let data = try? Data(contentsOf: path),
                      let parsed = EmlxParser.parse(data) else { continue }
                results.append((parsed, path))
            }
            return results
        }.value
    }

    /// Threads the whole parsed batch and maps each thread onto a
    /// `MailThread`. Messages with no `Message-ID` at all (malformed, but
    /// tolerated rather than dropped) get a synthesized id derived from the
    /// file path so they still surface as a singleton thread rather than
    /// vanishing.
    private func thread(_ messages: [EmlxMessage]) -> [MailThread] {
        let withIDs = messages.enumerated().map { index, emlx -> (String, EmlxMessage) in
            (emlx.message.messageID ?? "local-\(index)", emlx)
        }
        let byID = Dictionary(uniqueKeysWithValues: withIDs)
        let nodes = withIDs.map { id, emlx in
            LocalThreading.Node(messageID: id, references: emlx.message.references,
                               inReplyTo: emlx.message.inReplyTo)
        }
        let groups = LocalThreading.group(nodes)

        return groups.map { ids in
            let mailMessages = ids.compactMap { id in byID[id].map { (id, $0) } }
                .map { id, emlx in mailMessage(id: id, emlx: emlx) }
                .sorted { $0.date < $1.date }
            let threadID = ids.sorted().first ?? UUID().uuidString
            return MailThread(id: threadID, accountID: accountID, messages: mailMessages)
        }
    }

    private func mailMessage(id: String, emlx: EmlxMessage) -> MailMessage {
        let message = emlx.message
        return MailMessage(
            id: id,
            threadID: id,
            rfc822MessageID: message.messageID,
            from: message.from,
            to: message.to,
            cc: message.cc,
            subject: message.subject.isEmpty ? "(no subject)" : message.subject,
            date: message.date ?? .distantPast,
            isRead: emlx.isRead,
            isStarred: emlx.isFlagged,
            labelIDs: [],
            hasAttachments: false,
            snippet: String(message.plainText.prefix(140)))
    }
}
