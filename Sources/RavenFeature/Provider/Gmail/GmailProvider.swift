import Foundation

/// Gmail REST v1. Threading, labels, and search are server-side, so this maps
/// rather than computes.
public final class GmailProvider: MailProvider, @unchecked Sendable {
    public let accountID: String
    private let auth: GmailAuth
    private let session: URLSession
    private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    /// `session` defaults to `.shared` in production; tests inject a session
    /// backed by a stubbing `URLProtocol` so this provider is exercised
    /// end-to-end against recorded fixture bytes with no live network call.
    public init(accountID: String, auth: GmailAuth, session: URLSession = .shared) {
        self.accountID = accountID
        self.auth = auth
        self.session = session
    }

    private func get<T: Decodable>(_ type: T.Type, path: String,
                                   query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        let token = try await auth.accessToken(accountID: accountID)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(type, request: request)
    }

    private func post<T: Decodable>(_ type: T.Type, path: String,
                                    body: [String: Any]) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        let token = try await auth.accessToken(accountID: accountID)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(type, request: request)
    }

    /// Maps transport + status to domain errors. Two things are load-bearing
    /// here and must not regress:
    ///
    /// 1. A 404 becomes `MailError.unknownThread`, not `.providerFailed`.
    ///    `SyncEngine.syncDelta` treats ONLY `.unknownThread` as "this thread
    ///    is genuinely gone" — everything else is treated as transient and
    ///    holds the sync cursor. Mapping a deleted-thread 404 to
    ///    `.providerFailed` would wedge sync on that thread forever.
    ///    `threadIDForNotFound` lets call sites that know which thread they
    ///    were asking about supply the id; other 404s (which should not
    ///    happen against this API surface, but might under a future path)
    ///    fall back to `.providerFailed` since there is no thread id to report.
    /// 2. `.providerFailed`'s `message` is deliberately short — status plus a
    ///    brief reason, never the raw response body. `SyncEngine` persists
    ///    `String(describing:)` of the thrown error into `MailAccount.
    ///    lastError`, which is written to a document; a Gmail error body can
    ///    echo request context (e.g. malformed query parameters), so it must
    ///    never reach that field.
    private func perform<T: Decodable>(_ type: T.Type, request: URLRequest,
                                       threadIDForNotFound: String? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MailError.providerFailed(status: -1, message: "no response")
        }
        if http.statusCode == 404, let threadID = threadIDForNotFound {
            throw MailError.unknownThread(threadID)
        }
        if http.statusCode == 429 {
            // A missing `Retry-After` is itself unusual for a 429 but not
            // impossible; 30s is a conservative, sane fallback rather than
            // treating the absence as a decoding failure.
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 30
            throw MailError.rateLimited(retryAfter: retry)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MailError.providerFailed(status: http.statusCode,
                                           message: "Gmail API request failed")
        }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw MailError.decodingFailed(String(describing: type))
        }
        return decoded
    }

    // MARK: MailProvider

    /// Bound on concurrent per-thread fetches below. Gmail rate-limits
    /// aggressively (see the 429 handling in `perform`), so this is a small
    /// cap rather than "fire them all at once" — 5-6 in flight is enough to
    /// turn a ~50-thread page from 50 sequential round trips into ~10 while
    /// staying well clear of the limiter SyncEngine has to fail on.
    private static let maxConcurrentThreadFetches = 5

    public func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
        var query = [URLQueryItem(name: "q", value: "after:\(Int(since.timeIntervalSince1970))"),
                     URLQueryItem(name: "maxResults", value: "50")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let list = try await get(GmailListDTO.self, path: "threads", query: query)
        let references = list.threads ?? []

        // Fetched with BOUNDED concurrency (see `maxConcurrentThreadFetches`),
        // but slotted back into `slots` by original index so the returned
        // page's order is deterministic regardless of which request answers
        // first — callers (and tests) depend on that order matching the
        // listing order.
        var slots = [MailThread?](repeating: nil, count: references.count)
        try await withThrowingTaskGroup(of: (Int, MailThread?).self) { group in
            var nextIndex = 0
            func scheduleNext() {
                guard nextIndex < references.count else { return }
                let index = nextIndex
                let id = references[index].id
                nextIndex += 1
                group.addTask {
                    do {
                        return (index, try await self.fetchThread(id: id))
                    } catch MailError.unknownThread {
                        // Genuinely gone: a thread listed on page N can be
                        // deleted before we fetch it. Skipping (nil) is
                        // correct — there is nothing to store and it will
                        // never come back.
                        return (index, nil)
                    }
                    // Everything else (429, 500, a network blip) is
                    // TRANSIENT and is deliberately rethrown rather than
                    // swallowed. `SyncEngine.backfill()` seeds `syncCursor`
                    // on success, so a silently dropped thread here would be
                    // filed behind the cursor and no delta would ever
                    // re-deliver it — permanent, invisible mail loss. Failing
                    // the whole page instead means the cursor is NOT seeded
                    // and the next backfill re-walks: backfill is a fresh
                    // page walk and `upsertThread` is idempotent, so retrying
                    // costs bandwidth and nothing else. That is the opposite
                    // trade from `syncDelta`, where the *cursor* is the thing
                    // that cannot be replayed. Do not "simplify" this back
                    // into `try?`.
                }
            }
            for _ in 0..<min(Self.maxConcurrentThreadFetches, references.count) {
                scheduleNext()
            }
            while let (index, thread) = try await group.next() {
                slots[index] = thread
                scheduleNext()
            }
        }
        return ThreadPage(threads: slots.compactMap { $0 }, nextPageToken: list.nextPageToken)
    }

    public func fetchThread(id: String) async throws -> MailThread {
        var components = URLComponents(url: base.appendingPathComponent("threads/\(id)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "metadata")]
        var request = URLRequest(url: components.url!)
        let token = try await auth.accessToken(accountID: accountID)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let dto = try await perform(GmailThreadDTO.self, request: request, threadIDForNotFound: id)
        return GmailMapping.thread(dto, accountID: accountID)
    }

    public func fetchDelta(cursor: String) async throws -> MailDelta {
        let dto = try await get(GmailHistoryDTO.self, path: "history",
                                query: [URLQueryItem(name: "startHistoryId", value: cursor)])
        var changed = Set<String>()
        var removed = Set<String>()
        for entry in dto.history ?? [] {
            for reference in (entry.messagesAdded ?? []) + (entry.labelsAdded ?? [])
                + (entry.labelsRemoved ?? []) {
                changed.insert(reference.message.threadId)
            }
            for reference in entry.messagesDeleted ?? [] {
                removed.insert(reference.message.threadId)
            }
        }
        // When Gmail has nothing to report, `history` is absent entirely
        // (confirmed against the real `history.json` fixture) — that is an
        // empty delta, not an error, and the cursor still advances to
        // whatever `historyId` came back (or is held at `cursor` if even
        // that is missing).
        return MailDelta(changedThreadIDs: Array(changed.subtracting(removed)),
                         removedThreadIDs: Array(removed),
                         newCursor: dto.historyId ?? cursor)
    }

    public func fetchBody(messageID: String) async throws -> MessageBody {
        let dto = try await get(GmailMessageDTO.self, path: "messages/\(messageID)",
                                query: [URLQueryItem(name: "format", value: "full")])
        return GmailMapping.body(dto)
    }

    public func fetchAttachment(messageID: String, attachmentID: String) async throws -> Data {
        struct AttachmentDTO: Decodable { let data: String? }
        let dto = try await get(AttachmentDTO.self,
                                path: "messages/\(messageID)/attachments/\(attachmentID)")
        guard let encoded = dto.data,
              let decoded = GmailMapping.decodeAttachmentBase64URL(encoded) else {
            throw MailError.decodingFailed("attachment \(attachmentID)")
        }
        return decoded
    }

    public func fetchLabels() async throws -> [MailLabel] {
        GmailMapping.labels(try await get(GmailLabelsDTO.self, path: "labels"))
    }

    public func applyLabels(_ mutation: LabelMutation) async throws {
        struct Empty: Decodable {}
        for id in mutation.threadIDs {
            _ = try await post(Empty.self, path: "threads/\(id)/modify",
                               body: ["addLabelIds": mutation.add,
                                      "removeLabelIds": mutation.remove])
        }
    }

    public func send(_ message: OutgoingMessage) async throws -> String {
        struct Sent: Decodable { let id: String }
        var body: [String: Any] = ["raw": rfc822(message)]
        if let threadID = message.threadID { body["threadId"] = threadID }
        return try await post(Sent.self, path: "messages/send", body: body).id
    }

    public func currentCursor() async throws -> String {
        try await get(GmailProfileDTO.self, path: "profile").historyId
    }

    /// RFC822, base64url encoded as Gmail's `raw` field requires.
    ///
    /// **Every** header line is built by `MIMEHeader`, which sanitizes each
    /// value before encoding it. That is not stylistic: `RFC2047.encode`
    /// returns pure-ASCII input unchanged, so nothing used to validate an
    /// ASCII header value, and reply/forward subjects come from
    /// `thread.subject` while `In-Reply-To` is a raw remote `Message-ID` —
    /// both attacker-controlled. A subject of `"hello\r\nBcc: evil@x"` emitted
    /// a real `Bcc:` header. See `MIMEHeader` for why nothing here formats a
    /// `"Name: value"` string itself.
    ///
    /// `Subject` and any `To`/`Cc` display name is RFC 2047 encoded-word
    /// wrapped whenever it contains non-ASCII — RFC 5322 header field bodies
    /// are ASCII-only. A pure-ASCII value is left unencoded.
    ///
    /// The body is sent as `multipart/alternative`:
    /// - the plain part is `bodyText` as typed — including the
    ///   `body + "\n-- \n" + signature` its callers assembled — with only its
    ///   line endings normalised to CRLF, which RFC 2046 requires of a `text/*`
    ///   part and boundary recognition depends on. A bare `\n` in a MIME
    ///   structure this picky is exactly how a recipient ends up seeing raw
    ///   boundary markers;
    /// - the HTML part renders that same text via
    ///   `MarkdownToHTML.renderComposed`, which splits the signature off before
    ///   parsing so the sigdash is never mistaken for a setext heading.
    ///
    /// Both parts declare `Content-Transfer-Encoding: base64` and are actually
    /// base64d. They previously emitted raw UTF-8 under an implicit `7bit`,
    /// which was untrue of the bytes and left one long typed paragraph free to
    /// blow RFC 5322's 998-octet line limit. The boundary is a fresh random
    /// token checked against both parts before use, and every structural line
    /// uses CRLF.
    static func rfc822(_ message: OutgoingMessage) -> String {
        let html = MarkdownToHTML.renderComposed(message.bodyText)
        let boundary = randomBoundary(avoiding: [message.bodyText, html])

        var lines = [
            MIMEHeader.addressLine("To", message.to),
            MIMEHeader.line("Subject", message.subject),
            MIMEHeader.literalLine("MIME-Version", "1.0"),
        ]
        if !message.cc.isEmpty {
            lines.append(MIMEHeader.addressLine("Cc", message.cc))
        }
        if let inReplyTo = message.inReplyToMessageID {
            lines.append(MIMEHeader.literalLine("In-Reply-To", inReplyTo))
            lines.append(MIMEHeader.literalLine("References", inReplyTo))
        }
        lines.append(MIMEHeader.literalLine(
            "Content-Type", "multipart/alternative; boundary=\"\(boundary)\""))

        let body = [
            "--\(boundary)",
            MIMEHeader.literalLine("Content-Type", "text/plain; charset=UTF-8"),
            MIMEHeader.literalLine("Content-Transfer-Encoding", "base64"),
            "",
            MIMEHeader.base64Body(message.bodyText),
            "--\(boundary)",
            MIMEHeader.literalLine("Content-Type", "text/html; charset=UTF-8"),
            MIMEHeader.literalLine("Content-Transfer-Encoding", "base64"),
            "",
            MIMEHeader.base64Body(html),
            "--\(boundary)--",
            "",
        ].joined(separator: "\r\n")

        let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A boundary token guaranteed absent from every part it separates —
    /// otherwise a part containing a line that happens to match the boundary
    /// would truncate or corrupt the MIME structure. Astronomically unlikely
    /// with a fresh UUID per call, but checked (and re-rolled) rather than
    /// assumed.
    private static func randomBoundary(avoiding texts: [String]) -> String {
        var boundary = "raven-\(UUID().uuidString)"
        while texts.contains(where: { $0.contains(boundary) }) {
            boundary = "raven-\(UUID().uuidString)"
        }
        return boundary
    }

    private func rfc822(_ message: OutgoingMessage) -> String { Self.rfc822(message) }
}
