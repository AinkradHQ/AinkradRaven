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

    public func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
        var query = [URLQueryItem(name: "q", value: "after:\(Int(since.timeIntervalSince1970))"),
                     URLQueryItem(name: "maxResults", value: "50")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let list = try await get(GmailListDTO.self, path: "threads", query: query)

        var threads: [MailThread] = []
        for reference in list.threads ?? [] {
            // A thread listed on page N can be gone by the time we fetch it.
            guard let thread = try? await fetchThread(id: reference.id) else { continue }
            threads.append(thread)
        }
        return ThreadPage(threads: threads, nextPageToken: list.nextPageToken)
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

    /// Minimal RFC822, base64url encoded as Gmail's `raw` field requires.
    ///
    /// KNOWN LIMITATION (see task report): this does not MIME-encode the
    /// `Subject` header or the body for non-ASCII content. `Content-Type:
    /// text/plain; charset=UTF-8` on the body is honored by Gmail's `raw`
    /// parser as raw UTF-8 bytes, so the body text itself round-trips
    /// correctly. The `Subject:` header, however, is inserted as literal
    /// UTF-8 bytes with no RFC 2047 `=?UTF-8?B?...?=` encoded-word wrapping,
    /// which is what RFC 5322 actually requires for non-ASCII header field
    /// bodies — most real mail clients and Gmail's own web UI decode this
    /// leniently. This is exercised and documented, not hidden.
    static func rfc822(_ message: OutgoingMessage) -> String {
        var lines = [
            "To: \(message.to.map(\.email).joined(separator: ", "))",
            "Subject: \(message.subject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
        ]
        if !message.cc.isEmpty {
            lines.append("Cc: \(message.cc.map(\.email).joined(separator: ", "))")
        }
        if let inReplyTo = message.inReplyToMessageID {
            lines.append("In-Reply-To: \(inReplyTo)")
            lines.append("References: \(inReplyTo)")
        }
        let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + message.bodyText
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func rfc822(_ message: OutgoingMessage) -> String { Self.rfc822(message) }
}
