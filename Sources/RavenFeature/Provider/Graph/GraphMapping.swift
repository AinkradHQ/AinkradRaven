import Foundation

/// Pure wire-to-domain mapping for Microsoft Graph. No networking, so every
/// path here is unit-tested directly against recorded fixtures.
///
/// **Threading is server-side, so `LocalThreading` is deliberately not used
/// here.** Graph stamps every message with a `conversationId` that it computes
/// and maintains itself, exactly as Gmail stamps a `threadId` — so this file
/// *groups* by that id and never *computes* a thread. `LocalThreading` exists
/// for the backends that have no such id (the Apple Mail import, and IMAP,
/// which must reconstruct threads from `References`/`In-Reply-To`); reaching
/// for it here would replace an authoritative server answer with a local guess
/// and could split or merge conversations the server does not.
public enum GraphMapping {
    // MARK: Threads

    /// Groups a flat page of messages into threads by `conversationId`.
    ///
    /// Group order is **first-appearance order of the conversation in the
    /// page**, so a caller (and a test) sees the page in the order Graph
    /// listed it rather than in whatever order a dictionary happens to
    /// enumerate. Within a thread, messages are sorted oldest-first, because
    /// that is `MailThread.messages`' documented contract and everything
    /// downstream (subject-from-first, snippet-from-last) depends on it —
    /// Graph's own default ordering is newest-first, so this reverses it.
    ///
    /// A message with no `conversationId` at all (never seen from Graph, but
    /// the field is optional on the wire) falls back to being its own thread
    /// keyed by its message id — a thread of one, never merged with anything.
    public static func threads(_ messages: [GraphMessageDTO],
                               accountID: String) -> [MailThread] {
        var order: [String] = []
        var grouped: [String: [MailMessage]] = [:]
        for dto in messages {
            let conversationID = threadID(of: dto)
            if grouped[conversationID] == nil { order.append(conversationID) }
            grouped[conversationID, default: []].append(message(dto))
        }
        return order.map { id in
            MailThread(id: id, accountID: accountID,
                       messages: (grouped[id] ?? []).sorted { $0.date < $1.date })
        }
    }

    /// The thread id a message belongs to: its `conversationId`, or its own
    /// message id when Graph did not send one.
    public static func threadID(of dto: GraphMessageDTO) -> String {
        guard let conversationID = dto.conversationId, !conversationID.isEmpty else {
            return dto.id
        }
        return conversationID
    }

    // MARK: Messages

    public static func message(_ dto: GraphMessageDTO) -> MailMessage {
        MailMessage(
            id: dto.id,
            threadID: threadID(of: dto),
            rfc822MessageID: dto.internetMessageId,
            from: address(dto.from),
            to: (dto.toRecipients ?? []).compactMap(address),
            cc: (dto.ccRecipients ?? []).compactMap(address),
            subject: dto.subject ?? "(no subject)",
            date: date(dto.receivedDateTime),
            // Graph's field is positive (`isRead`), where Gmail's is a
            // negative label (`UNREAD`). Absent means unread: an unknown
            // message is better shown as new than silently marked read.
            isRead: dto.isRead ?? false,
            // `"complete"` is a flag that has been *cleared by completing
            // it* — the user is done with it, so it is not starred. Only
            // `"flagged"` is.
            isStarred: dto.flag?.flagStatus == "flagged",
            labelIDs: labelIDs(dto),
            hasAttachments: dto.hasAttachments ?? false,
            snippet: dto.bodyPreview ?? "",
            // Attachment METADATA is not carried on a message resource —
            // Graph only exposes it from `/messages/{id}/attachments`, a
            // separate round trip per message that a page walk must not make.
            // `hasAttachments` above still tells the UI there are some.
            attachments: [])
    }

    /// What this message is filed under, as ids: its parent folder first, then
    /// its categories.
    ///
    /// Both, not either. The folder is Graph's equivalent of Gmail's system
    /// labels (a message lives in exactly one), and categories are its
    /// equivalent of user labels (a message may carry many). Storing the
    /// folder ID rather than its display name is what keeps this stable when
    /// a user renames a folder.
    private static func labelIDs(_ dto: GraphMessageDTO) -> [String] {
        var ids: [String] = []
        if let folder = dto.parentFolderId, !folder.isEmpty { ids.append(folder) }
        ids.append(contentsOf: dto.categories ?? [])
        return ids
    }

    private static func address(_ recipient: GraphMessageDTO.Recipient?) -> MailAddress? {
        guard let email = recipient?.emailAddress?.address, !email.isEmpty else { return nil }
        let name = recipient?.emailAddress?.name
        return MailAddress(email: email, name: (name?.isEmpty == false) ? name : nil)
    }

    /// Graph timestamps are ISO 8601 in UTC, with fractional seconds present
    /// on some resources and absent on others. Both are parsed; anything else
    /// falls back to the epoch rather than throwing, so one unparseable
    /// timestamp cannot fail a whole page.
    static func date(_ raw: String?) -> Date {
        guard let raw else { return Date(timeIntervalSince1970: 0) }
        // `Date.ISO8601FormatStyle`, not `ISO8601DateFormatter`: the formatter
        // is a non-`Sendable` class, so a shared static instance of it is not
        // concurrency-safe under Swift 6 and a per-call one is wasteful. The
        // format style is a value type.
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(raw) { return parsed }
        if let parsed = try? Date.ISO8601FormatStyle().parse(raw) { return parsed }
        return Date(timeIntervalSince1970: 0)
    }

    // MARK: Bodies

    /// One message's body.
    ///
    /// **The HTML is stored raw and is sanitised only onto the `plainText`
    /// path** — byte-identical policy to `GmailMapping.body` and
    /// `IMAPFetchParser.body`, and deliberately so. `BodySanitizer` has no
    /// HTML→HTML entry point: it produces plain TEXT whose contract is that it
    /// is never re-rendered as markup. Putting its output in `html` would both
    /// break "Show original" and make Graph disagree with the other two
    /// backends about the same message.
    ///
    /// **Which source feeds which field.** `html` is always the FULL `body`,
    /// so nothing the message contained is ever lost — "Show original" shows
    /// all of it. `plainText` prefers `uniqueBody` (the message with the
    /// quoted conversation history stripped, which is the whole reason Graph
    /// offers it) and falls back to `body` when it is absent or empty, which
    /// is what happens whenever the caller did not `$select` it.
    ///
    /// A `contentType` of `"text"` means the content is already plain text and
    /// must NOT go through the sanitiser (it would eat a literal `<` in
    /// prose); in that case `html` stays `nil`.
    ///
    /// Known gap, stated rather than hidden: `icsText` is always `nil` here.
    /// Graph does not expose a calendar invite as a body part — it arrives as
    /// an `itemAttachment`/`event`, a shape this read path does not fetch — so
    /// the invite card does not light up for a Graph account yet.
    public static func body(_ dto: GraphMessageDTO) -> MessageBody {
        let full = dto.body
        let unique = dto.uniqueBody
        let isHTML = (full?.contentType ?? "").caseInsensitiveCompare("html") == .orderedSame
        let html = isHTML ? full?.content : nil

        let preferred = nonEmpty(unique?.content) ?? nonEmpty(full?.content) ?? ""
        let uniqueIsHTML = unique.map {
            ($0.contentType ?? "").caseInsensitiveCompare("html") == .orderedSame
        } ?? false
        let sourceIsHTML = nonEmpty(unique?.content) != nil ? uniqueIsHTML : isHTML
        let plainText = sourceIsHTML ? BodySanitizer.plainText(fromHTML: preferred) : preferred

        return MessageBody(messageID: dto.id, plainText: plainText, html: html, icsText: nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: Folders

    /// Mail folders as labels. `wellKnownName` — not `displayName` — decides
    /// whether a folder is a system one: display names are localised and
    /// user-renameable, so keying on them misclassifies every non-English
    /// mailbox.
    public static func labels(_ dto: GraphFolderListDTO) -> [MailLabel] {
        (dto.value ?? []).map { folder in
            MailLabel(id: folder.id,
                      name: folder.displayName ?? folder.id,
                      kind: (folder.wellKnownName?.isEmpty == false) ? .system : .user)
        }
    }

    // MARK: Delta

    /// Turns the accumulated entries of a delta walk into a `MailDelta`.
    ///
    /// A `@removed` entry is a deleted MESSAGE, and Graph does not guarantee
    /// it carries `conversationId`. When it does not, the deletion **cannot be
    /// attributed to a thread** and is dropped: the alternative — using the
    /// message id as a thread id, which is the shape this would naturally
    /// collapse into — would hand `SyncEngine` an id that matches no stored
    /// thread, and on a provider where ids ever collided would delete the
    /// wrong conversation. The cost of dropping it is that the thread keeps a
    /// stale message until something else changes in it; the cost of guessing
    /// is losing a different conversation, so this errs the safe way.
    ///
    /// `changed` minus `removed`, matching `GmailProvider.fetchDelta`: a
    /// conversation that both gained and lost a message is *changed*, and
    /// re-fetching it is what resolves which messages remain.
    public static func delta(entries: [GraphMessageDTO], newCursor: String) -> MailDelta {
        var changed: [String] = []
        var removed: [String] = []
        var seenChanged = Set<String>()
        var seenRemoved = Set<String>()
        for entry in entries {
            if entry.removed != nil {
                guard let conversationID = entry.conversationId, !conversationID.isEmpty else {
                    continue
                }
                if seenRemoved.insert(conversationID).inserted { removed.append(conversationID) }
            } else {
                let id = threadID(of: entry)
                if seenChanged.insert(id).inserted { changed.append(id) }
            }
        }
        return MailDelta(changedThreadIDs: changed,
                         removedThreadIDs: removed.filter { !seenChanged.contains($0) },
                         newCursor: newCursor)
    }

    /// The `$deltatoken` value out of a `@odata.deltaLink`.
    ///
    /// **The cursor stored in `MailAccount.syncCursor` is this bare token
    /// string, not the whole link.** `syncCursor` is a plain `String?` that
    /// other backends fill with a plain scalar (Gmail's `historyId`), and a
    /// full URL there would be a second, URL-shaped thing to keep valid across
    /// tenant/host changes. `GraphProvider` rebuilds the request from the
    /// token, so the round trip is: link → token → `syncCursor` → request.
    public static func deltaToken(inLink link: String?) -> String? {
        guard let link,
              let components = URLComponents(string: link),
              let token = components.queryItems?.first(where: { $0.name == "$deltatoken" })?.value,
              !token.isEmpty else { return nil }
        return token
    }
}
