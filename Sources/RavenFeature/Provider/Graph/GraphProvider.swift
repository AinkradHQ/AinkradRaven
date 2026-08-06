import Foundation

/// Microsoft Graph v1.0, read paths.
///
/// Structurally parallel to `GmailProvider`: threading, folders and search are
/// all server-side, so this maps rather than computes — see `GraphMapping` for
/// why `LocalThreading` has no part in it.
///
/// Write paths (`send`, `applyLabels`) are Task 20's. Until they land this
/// provider declares `.readOnly`, which makes `MailProviderRouter` refuse a
/// mutation *before* it reaches the provider, for every caller, rather than
/// each call site having to remember that Graph cannot write yet.
public final class GraphProvider: MailProvider, @unchecked Sendable {
    public let accountID: String
    /// Read paths only in Task 19 — see the type's documentation.
    public let capabilities: MailProviderCapabilities = .readOnly
    private let auth: GraphAuth
    private let session: URLSession
    private let base = URL(string: "https://graph.microsoft.com/v1.0/me/")!

    /// The fields every message-listing request asks for. Explicit rather than
    /// default, for two reasons: Graph's default projection does NOT include
    /// `uniqueBody` at all, and it DOES include the full `body` of every
    /// message in a page — which would make a 50-message page walk drag whole
    /// message bodies across the wire during a metadata-only sync.
    private static let messageFields = [
        "id", "conversationId", "internetMessageId", "subject", "bodyPreview",
        "receivedDateTime", "isRead", "hasAttachments", "parentFolderId",
        "categories", "flag", "from", "toRecipients", "ccRecipients",
    ].joined(separator: ",")

    private static let pageSize = 50

    /// Bound on how many `@odata.nextLink` hops one delta walk will follow.
    /// A delta walk is unattended, so an endpoint that kept handing back a
    /// next link would otherwise spin forever; stopping and reporting the
    /// token we have is recoverable, an infinite loop is not.
    private static let maxDeltaPages = 50

    /// `session` defaults to `.shared` in production; tests inject a session
    /// backed by `StubURLProtocol` so this provider is exercised end-to-end
    /// against recorded fixture bytes with no live network call.
    public init(accountID: String, auth: GraphAuth, session: URLSession = .shared) {
        self.accountID = accountID
        self.auth = auth
        self.session = session
    }

    // MARK: Transport

    private func get<T: Decodable>(_ type: T.Type, path: String,
                                   query: [URLQueryItem] = [],
                                   notFoundID: String? = nil) async throws -> T {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return try await get(type, url: components.url!, notFoundID: notFoundID)
    }

    /// The absolute-URL form, used to follow an `@odata.nextLink` verbatim.
    /// Graph's paging links are opaque and must be replayed exactly, not
    /// rebuilt from their parts.
    private func get<T: Decodable>(_ type: T.Type, url: URL,
                                   notFoundID: String? = nil) async throws -> T {
        var request = URLRequest(url: url)
        let token = try await auth.accessToken(accountID: accountID)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(type, request: request, notFoundID: notFoundID)
    }

    /// Maps transport + status to domain errors. Three mappings are
    /// load-bearing and must not regress:
    ///
    /// 1. **410 Gone stays a `providerFailed(status: 410, …)`.** Graph answers
    ///    a delta request whose `$deltatoken` has aged out with 410 (and
    ///    `SyncStateNotFound`). `SyncEngine.syncDelta` catches exactly
    ///    `providerFailed` with status 404 or 410 from `fetchDelta` and
    ///    answers it with a full `backfill()` — that is M0's correction, and
    ///    this provider plugs into it unchanged rather than growing a second
    ///    recovery path. Mapping 410 to anything else (a bespoke error case, a
    ///    `decodingFailed`) would leave the account wedged on a dead cursor
    ///    forever, because every OTHER error deliberately holds the cursor.
    /// 2. A 404 becomes `MailError.unknownThread` when the caller knows which
    ///    thread it asked about — same rule, for the same reason, as
    ///    `GmailProvider.perform`: only `.unknownThread` tells `SyncEngine`
    ///    "this is genuinely gone".
    /// 3. `.providerFailed`'s `message` is a fixed phrase, never the response
    ///    body. `SyncEngine` persists `String(describing:)` of the error into
    ///    `MailAccount.lastError`, which is written to a document; a Graph
    ///    error body echoes the request (`$filter` contents and all), so it
    ///    must never reach that field.
    private func perform<T: Decodable>(_ type: T.Type, request: URLRequest,
                                       notFoundID: String? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MailError.providerFailed(status: -1, message: "no response")
        }
        if http.statusCode == 404, let notFoundID {
            throw MailError.unknownThread(notFoundID)
        }
        if http.statusCode == 429 {
            // A missing `Retry-After` is unusual for a 429 but not impossible;
            // 30s is the same conservative fallback `GmailProvider` uses,
            // rather than treating the absence as a decoding failure.
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 30
            throw MailError.rateLimited(retryAfter: retry)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MailError.providerFailed(status: http.statusCode,
                                           message: "Graph API request failed")
        }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw MailError.decodingFailed(String(describing: type))
        }
        return decoded
    }

    // MARK: MailProvider — reads

    public func fetchThreads(since: Date, pageToken: String?) async throws -> ThreadPage {
        let list: GraphMessageListDTO
        if let pageToken, let url = URL(string: pageToken) {
            list = try await get(GraphMessageListDTO.self, url: url)
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            list = try await get(GraphMessageListDTO.self, path: "messages", query: [
                .init(name: "$filter", value: "receivedDateTime ge \(formatter.string(from: since))"),
                .init(name: "$orderby", value: "receivedDateTime desc"),
                .init(name: "$top", value: "\(Self.pageSize)"),
                .init(name: "$select", value: Self.messageFields),
            ])
        }
        // No per-thread follow-up round trip, unlike Gmail: a Graph page
        // already carries whole messages, so the conversation grouping is
        // done locally from what came back. A conversation whose other
        // messages fall on a later page is completed by `upsertThread`'s
        // merge on the next page, exactly as it is for any provider whose
        // pages cut across a thread.
        return ThreadPage(threads: GraphMapping.threads(list.value ?? [], accountID: accountID),
                          nextPageToken: list.nextLink)
    }

    /// One conversation, by `conversationId`.
    ///
    /// `$filter=conversationId eq '…'` rather than a `/threads/{id}` resource,
    /// because Graph has no conversation resource on the mail API — the
    /// conversation is only ever a property of its messages. An id that
    /// matches no message is `unknownThread`, not an empty thread: an empty
    /// `MailThread` would be upserted over a real stored one and blank the
    /// conversation.
    public func fetchThread(id: String) async throws -> MailThread {
        // A single quote inside the id would terminate the OData string
        // literal; OData escapes it by doubling. Graph's own ids never
        // contain one, but this is a value from the wire reaching a query
        // language, so it is escaped rather than trusted.
        let escaped = id.replacingOccurrences(of: "'", with: "''")
        let list = try await get(GraphMessageListDTO.self, path: "messages", query: [
            .init(name: "$filter", value: "conversationId eq '\(escaped)'"),
            .init(name: "$top", value: "\(Self.pageSize)"),
            .init(name: "$select", value: Self.messageFields),
        ], notFoundID: id)
        let messages = list.value ?? []
        guard !messages.isEmpty else { throw MailError.unknownThread(id) }
        // Grouped, then reduced to the one conversation asked for. Graph
        // cannot return a message from another conversation for this filter,
        // but reusing the same grouping keeps the message ORDER identical to
        // what `fetchThreads` produces for the same conversation.
        let threads = GraphMapping.threads(messages, accountID: accountID)
        guard let thread = threads.first(where: { $0.id == id }) ?? threads.first else {
            throw MailError.unknownThread(id)
        }
        return thread
    }

    /// What changed since `cursor`, where `cursor` is the bare `$deltatoken`
    /// string held in `MailAccount.syncCursor` (see `GraphMapping.deltaToken`).
    ///
    /// Scoped to the Inbox, because Graph's message delta is a per-folder
    /// function — there is no mailbox-wide message delta in v1.0. That matches
    /// what the sync window is for (new mail arriving), and a change made in
    /// another folder is picked up by the next backfill rather than by a delta.
    ///
    /// A walk pages through `@odata.nextLink` until the response carries an
    /// `@odata.deltaLink`; that link's token is the new cursor. If the walk hits
    /// `maxDeltaPages` first, the cursor is held at `cursor` so the same ground
    /// is re-walked next time — replaying a delta is idempotent (`upsertThread`
    /// is), whereas advancing past unread pages would lose them permanently.
    public func fetchDelta(cursor: String) async throws -> MailDelta {
        var entries: [GraphMessageDTO] = []
        var next: URL? = nil
        var newToken: String? = nil
        var pages = 0

        repeat {
            let page: GraphMessageListDTO
            if let url = next {
                page = try await get(GraphMessageListDTO.self, url: url)
            } else {
                page = try await get(GraphMessageListDTO.self,
                                     path: "mailFolders/inbox/messages/delta",
                                     query: [.init(name: "$deltatoken", value: cursor)])
            }
            entries.append(contentsOf: page.value ?? [])
            newToken = GraphMapping.deltaToken(inLink: page.deltaLink)
            next = page.nextLink.flatMap(URL.init(string:))
            pages += 1
        } while next != nil && newToken == nil && pages < Self.maxDeltaPages

        return GraphMapping.delta(entries: entries, newCursor: newToken ?? cursor)
    }

    public func fetchBody(messageID: String) async throws -> MessageBody {
        let dto = try await get(GraphMessageDTO.self, path: "messages/\(messageID)",
                                query: [.init(name: "$select",
                                              value: "id,conversationId,body,uniqueBody")],
                                notFoundID: nil)
        return GraphMapping.body(dto)
    }

    public func fetchAttachment(messageID: String, attachmentID: String) async throws -> Data {
        let dto = try await get(GraphAttachmentDTO.self,
                                path: "messages/\(messageID)/attachments/\(attachmentID)")
        // Standard padded base64, NOT Gmail's base64url — decoding this with
        // Gmail's decoder would succeed on some inputs and corrupt others.
        guard let encoded = dto.contentBytes, let decoded = Data(base64Encoded: encoded) else {
            throw MailError.decodingFailed("attachment \(attachmentID)")
        }
        return decoded
    }

    public func fetchLabels() async throws -> [MailLabel] {
        GraphMapping.labels(try await get(GraphFolderListDTO.self, path: "mailFolders",
                                          query: [.init(name: "$top", value: "100")]))
    }

    /// The newest cursor available right now, for seeding after a backfill.
    ///
    /// `$deltatoken=latest` is Graph's own "give me a token for the current
    /// state without sending me the state" — the response carries an
    /// `@odata.deltaLink` and no items, which is exactly what seeding needs.
    public func currentCursor() async throws -> String {
        let page = try await get(GraphMessageListDTO.self,
                                 path: "mailFolders/inbox/messages/delta",
                                 query: [.init(name: "$deltatoken", value: "latest")])
        guard let token = GraphMapping.deltaToken(inLink: page.deltaLink) else {
            throw MailError.decodingFailed("graph delta token")
        }
        return token
    }

    /// Full-archive search via Graph's `$search`, grouped into conversations.
    ///
    /// The caller's query is passed through untranslated, matching
    /// `MailProvider.searchThreads`' contract: KQL is close to but not the same
    /// as `ThreadSearch.parse`'s grammar, and the server's interpretation is
    /// authoritative for what a remote hit is.
    ///
    /// Untranslated is not the same as unescaped: the query is a wire value
    /// reaching a query language, so the KQL string's own delimiters are
    /// escaped before it is embedded — the same rule, for the same reason,
    /// that `fetchThread` doubles `'` for its OData literal. A subject
    /// containing a `"` (`Re: the "final" draft`) otherwise closes the KQL
    /// string early and produces a malformed `$search` the server rejects.
    ///
    /// `limit` bounds MESSAGES requested, and the threads they group into are
    /// then capped at `limit` too — grouping can only ever reduce the count, so
    /// this cannot return more than asked for.
    public func searchThreads(query: String, limit: Int) async throws -> [MailThread] {
        guard limit > 0 else { return [] }
        // Backslash FIRST, then the quote: escaping the quote first would then
        // have its own escape character re-escaped, turning `\"` back into a
        // literal backslash followed by a string terminator.
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let list = try await get(GraphMessageListDTO.self, path: "messages", query: [
            // `$search` takes a quoted KQL string; `$orderby` is not allowed
            // alongside it, so results come back in relevance order.
            .init(name: "$search", value: "\"\(escaped)\""),
            .init(name: "$top", value: "\(min(Self.pageSize, limit))"),
            .init(name: "$select", value: Self.messageFields),
        ])
        return Array(GraphMapping.threads(list.value ?? [], accountID: accountID).prefix(limit))
    }

    // MARK: MailProvider — writes (Task 20)

    /// Refused here as well as at the router. `capabilities` is `.readOnly`, so
    /// `MailProviderRouter.writableProvider` never routes a mutation here at
    /// all; this exists so that a caller holding the provider DIRECTLY still
    /// gets a typed refusal instead of a silent no-op that looks like success.
    public func applyLabels(_ mutation: LabelMutation) async throws {
        throw MailError.readOnlyAccount(accountID)
    }

    /// Refused for the same reason as `applyLabels`. **A throw, never a
    /// fabricated message id:** at-most-once send is built on a RECORDED
    /// success, so returning anything here would record a send that never
    /// happened.
    public func send(_ message: OutgoingMessage) async throws -> String {
        throw MailError.readOnlyAccount(accountID)
    }
}
