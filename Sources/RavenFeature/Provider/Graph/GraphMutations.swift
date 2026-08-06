import Foundation

/// `GraphProvider`'s write paths: `applyLabels` and `send`.
///
/// Split from `GraphProvider.swift` for the repo's line limit, along the same seam
/// `IMAPProvider`/`IMAPProvider+Mutations` uses — that file walks the mailbox and
/// decides what changed, this one issues requests about messages the caller named.
///
/// **Verified against recorded fixtures and `StubURLProtocol` only.** There is no
/// Azure app registration in this build; live verification is Task 24's.
extension GraphProvider {

    // MARK: - Transport for writes

    /// A `POST`/`PATCH` carrying a JSON object, decoded into `T`.
    ///
    /// Shares `perform` with every read, so a write inherits the *same* error
    /// mapping — 429 → `.rateLimited(retryAfter:)`, a non-2xx →
    /// `.providerFailed(status:message:)` with a FIXED phrase and never the
    /// response body. That last one matters more on a write than a read:
    /// `SyncEngine` persists `String(describing:)` of an error into
    /// `MailAccount.lastError`, and a Graph error body echoes the request — which
    /// on this path contains the message the user just typed.
    func write<T: Decodable>(_ type: T.Type, method: String, path: String,
                             json: [String: Any]?) async throws -> T {
        try await perform(type, request: try await request(method, path: path, json: json))
    }

    /// A request whose success carries **no body at all** — Graph answers
    /// `POST /messages/{id}/send` with `202 Accepted` and zero bytes.
    ///
    /// It cannot go through `perform`, which decodes unconditionally and would turn
    /// every successful send into `decodingFailed`. Status is still checked, so a
    /// refusal is still a throw.
    func writeExpectingNoContent(method: String, path: String,
                                 json: [String: Any]?) async throws {
        let (_, response) = try await session.data(
            for: try await request(method, path: path, json: json))
        guard let http = response as? HTTPURLResponse else {
            throw MailError.providerFailed(status: -1, message: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MailError.providerFailed(status: http.statusCode,
                                           message: "Graph API request failed")
        }
    }

    private func request(_ method: String, path: String,
                         json: [String: Any]?) async throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        let token = try await auth.accessToken(accountID: accountID)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // `.sortedKeys` so the bytes on the wire are deterministic: a test can
            // then assert the whole body, and a diff between two runs means the
            // payload really changed rather than a dictionary re-ordering.
            request.httpBody = try JSONSerialization.data(withJSONObject: json,
                                                          options: [.sortedKeys])
        }
        return request
    }

    // MARK: - applyLabels

    /// Applies a mutation rendered by `GraphVocabulary`.
    ///
    /// The rendered strings are three different kinds of thing, and the split is
    /// made on the string itself — never on a second table kept in parallel with
    /// the vocabulary — into the three requests Graph actually has:
    ///
    /// - **`\Unread` / `\Flagged`** → `PATCH /me/messages/{id}` setting `isRead`
    ///   and `flag.flagStatus`. `\Unread` is inverted here and ONLY here: adding it
    ///   is `isRead: false`, removing it is `isRead: true`. See `GraphVocabulary`
    ///   for why the pseudo-flag exists at all.
    /// - **`folder:<wellKnownName>`** → `POST /me/messages/{id}/move`, because on a
    ///   folder backend "gaining a folder" and "losing a folder" are one act.
    /// - **anything else** → a **category**, written as the message's whole
    ///   `categories` array on the same `PATCH`.
    ///
    /// ## Ordering, which is not interchangeable
    ///
    /// The `PATCH` happens BEFORE the move. `/move` mints a **new message id** —
    /// the message is recreated in the destination folder — so patching afterwards
    /// would address an id that no longer exists and fail with a 404 on every
    /// archive-and-mark-read.
    ///
    /// ## Categories are read-modify-write, and why that is not a lost update here
    ///
    /// Graph has no add/remove verb for categories: the array is replaced whole. So
    /// the current value is read back on the same request that expands the
    /// conversation, then edited. A concurrent change made elsewhere between the
    /// read and the `PATCH` would be overwritten — the same exposure Gmail's
    /// `threads/{id}/modify` does not have. It is bounded to categories (never to
    /// read state, the star, or the folder, which are set as absolute values) and
    /// the losing write is re-read by the next sync.
    ///
    /// ## Why every thread costs a lookup
    ///
    /// `LabelMutation.threadIDs` are `conversationId`s, and Graph has no
    /// conversation resource on the mail API — every write addresses one message.
    /// So each conversation is expanded to its messages first, exactly as
    /// `IMAPProvider.applyLabels` expands a thread to UIDs through its index.
    public func applyLabels(_ mutation: LabelMutation) async throws {
        let addFlags = mutation.add.filter(GraphVocabulary.isSystemFlag)
        let removeFlags = mutation.remove.filter(GraphVocabulary.isSystemFlag)
        let addedFolders = mutation.add.compactMap(GraphVocabulary.wellKnownFolder(in:))
        let removedFolders = mutation.remove.compactMap(GraphVocabulary.wellKnownFolder(in:))
        let addedCategories = mutation.add.filter(GraphVocabulary.isCategory)
        let removedCategories = mutation.remove.filter(GraphVocabulary.isCategory)

        var properties: [String: Any] = [:]
        if addFlags.contains(GraphVocabulary.unreadPseudoFlag) { properties["isRead"] = false }
        if removeFlags.contains(GraphVocabulary.unreadPseudoFlag) { properties["isRead"] = true }
        if addFlags.contains(GraphVocabulary.flaggedFlag) {
            properties["flag"] = ["flagStatus": "flagged"]
        }
        if removeFlags.contains(GraphVocabulary.flaggedFlag) {
            // `notFlagged`, not `complete`: completing a flag is the user saying
            // they finished the task, which Graph keeps a record of.
            // `GraphMapping.message` already reads `complete` as NOT starred, so
            // writing it here would be a different act that happens to look the
            // same in the list.
            properties["flag"] = ["flagStatus": "notFlagged"]
        }
        let touchesCategories = !addedCategories.isEmpty || !removedCategories.isEmpty
        let destination = Self.moveDestination(added: addedFolders, removed: removedFolders)
        guard !properties.isEmpty || touchesCategories || destination != nil else { return }

        for threadID in mutation.threadIDs {
            for message in try await conversationMessages(threadID) {
                var body = properties
                if touchesCategories {
                    body["categories"] = Self.categories(message.categories ?? [],
                                                         adding: addedCategories,
                                                         removing: removedCategories)
                }
                if !body.isEmpty {
                    _ = try await write(GraphEmptyDTO.self, method: "PATCH",
                                        path: "messages/\(message.id)", json: body)
                }
                if let destination {
                    _ = try await write(GraphEmptyDTO.self, method: "POST",
                                        path: "messages/\(message.id)/move",
                                        json: ["destinationId": destination])
                }
            }
        }
    }

    /// Where a move should land, or `nil` when no move was asked for.
    ///
    /// `ThreadAction` is written in canonical flags shaped by Gmail's model: archive
    /// is `remove: [.inbox]` with nothing added, trash is `add: [.trash],
    /// remove: [.inbox]`. So an **added** folder is the destination, and otherwise
    /// a **removed** folder means "move out of here", whose only non-destructive
    /// answer on a folder backend is the archive.
    ///
    /// Unlike IMAP's equivalent this cannot fail to resolve: `archive` is a Graph
    /// `wellKnownName` that every mailbox has, so there is no account for which an
    /// archive silently becomes a no-op.
    static func moveDestination(added: [String], removed: [String]) -> String? {
        if let target = added.first { return target }
        guard !removed.isEmpty else { return nil }
        return "archive"
    }

    /// The new `categories` array: removals first, then additions, and no
    /// duplicates. Order of the surviving entries is preserved, so a `PATCH` that
    /// changes nothing sends back exactly what Graph had.
    static func categories(_ current: [String], adding: [String],
                           removing: [String]) -> [String] {
        var result = current.filter { !removing.contains($0) }
        for category in adding where !result.contains(category) { result.append(category) }
        return result
    }

    /// The messages of one conversation, with the fields a write needs.
    ///
    /// `$select=id,categories` and nothing else: this runs once per thread in a
    /// mutation, and the default projection would drag every message's full body
    /// across the wire to set one boolean — the same reason
    /// `GraphProvider.messageFields` is explicit.
    ///
    /// An empty result is `unknownThread`, not a silent success. A mutation that
    /// matched nothing must be reported: `Outbox` distinguishes "applied" from
    /// "the thread is gone", and returning normally here would tell it the label
    /// was written when no message was touched.
    private func conversationMessages(_ threadID: String) async throws -> [GraphMessageDTO] {
        // Doubled per OData's escaping rule, for the same reason
        // `GraphProvider.fetchThread` doubles it: this is a value from the store
        // reaching a query language.
        let escaped = threadID.replacingOccurrences(of: "'", with: "''")
        let list = try await get(GraphMessageListDTO.self, path: "messages", query: [
            .init(name: "$filter", value: "conversationId eq '\(escaped)'"),
            .init(name: "$select", value: "id,categories"),
        ], notFoundID: threadID)
        let messages = list.value ?? []
        guard !messages.isEmpty else { throw MailError.unknownThread(threadID) }
        return messages
    }

    // MARK: - send

    /// Transmits `message` and returns the id Graph minted for it.
    ///
    /// Two requests, and which one is which matters for at-most-once:
    ///
    /// 1. `POST /me/messages` creates the draft from `GraphSendPayload.draft` and
    ///    answers `201` with the message resource. **Its `id` is the recorded
    ///    success** this method returns — see `GraphSendPayload` for why the
    ///    one-shot `sendMail` shape (202, empty body, no id) was rejected: it would
    ///    force fabricating one, which is precisely what the read-only period
    ///    refused to do. A response with no usable `id` is `decodingFailed`, never
    ///    a made-up value.
    /// 2. `POST /me/messages/{id}/send` commits it and answers `202` with no body.
    ///
    /// ## At-most-once
    ///
    /// Failures of the two steps are NOT the same failure, and conflating them is
    /// how a send goes out twice:
    ///
    /// - **Step 1 failing means nothing was sent.** The message never left the
    ///   draft state, so the error propagates as thrown and `Outbox.drain` retries
    ///   it with backoff like any other transient provider failure. That is
    ///   correct, and it is what keeps the criterion below falsifiable.
    /// - **Step 2 failing means the outcome is UNKNOWN**, so it becomes
    ///   `MailError.sendOutcomeUnknown` — which `OutboxFailure` classifies as
    ///   `.review` and `Outbox.drain` holds as `OutboxSendOutcome.needsReview`,
    ///   never auto-retrying.
    ///
    /// The unknown verdict covers a non-2xx as well as a dropped connection, and
    /// deliberately so: once the commit request has left, we cannot tell a server
    /// that refused it from one that accepted it and failed to answer. This is the
    /// same direction `SMTPSession.finishData` takes after `DATA` — hold for a
    /// human rather than risk a duplicate — and it is the one failure this app's
    /// send path is built never to risk. Nothing here catches step 2's error and
    /// continues, and nothing infers success from the absence of an error.
    public func send(_ message: OutgoingMessage) async throws -> String {
        let draft = try await write(GraphCreatedMessageDTO.self, method: "POST",
                                    path: "messages",
                                    json: GraphSendPayload.draft(for: message))
        guard let id = draft.id, !id.isEmpty else {
            throw MailError.decodingFailed("graph draft id")
        }
        do {
            try await writeExpectingNoContent(method: "POST", path: "messages/\(id)/send",
                                              json: nil)
        } catch {
            // Fixed phrasing, and no server text: this string reaches
            // `OutboxEntry.lastError` and the composer banner. `\(id)` is a Graph
            // message id, not content.
            throw MailError.sendOutcomeUnknown(
                message: "the send request for Graph draft \(id) left without a verdict")
        }
        return id
    }
}

/// A response whose body is a JSON object nobody reads — a `PATCH`'s or a
/// `/move`'s echo of the message. Decoding it is still how the status check and
/// the "the server answered JSON at all" check happen.
struct GraphEmptyDTO: Decodable {}

/// `POST /me/messages`' answer: the created draft.
///
/// `id` is optional on the wire even though Graph always sends it, so that an
/// absent one is a typed `decodingFailed` at the one call site that cares rather
/// than a decode failure that reads like a transport bug.
struct GraphCreatedMessageDTO: Decodable {
    let id: String?
}
