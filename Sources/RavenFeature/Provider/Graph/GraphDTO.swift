import Foundation

/// Wire shapes for Microsoft Graph v1.0 (`/me/messages`, `/me/mailFolders`,
/// the `/messages/delta` function, and `/me`). These decode exactly what Graph
/// sends; `GraphMapping` turns them into the domain model.
///
/// Two Graph-specific decoding facts are load-bearing here:
///
/// 1. **Annotation keys are not identifiers.** `@odata.nextLink`,
///    `@odata.deltaLink` and `@removed` cannot be spelled as Swift property
///    names, so every type that carries one declares an explicit `CodingKeys`
///    with the literal string. Getting one of these wrong does not fail a
///    decode — the key is simply absent — so a typo shows up as "delta never
///    terminates" or "nothing was ever removed", never as an error. Each is
///    covered by a fixture.
/// 2. **A `@removed` entry is not a message.** Graph sends `{"id": …,
///    "@removed": {"reason": …}}` with *no* other field guaranteed — in
///    particular `conversationId` may be absent, and when it is, the deleted
///    message cannot be attributed to a thread at all. `GraphMapping.delta`
///    says what it does about that; it must not fall back to the message id,
///    which is not a thread id.
public struct GraphMessageDTO: Decodable {
    public struct EmailAddress: Decodable {
        public let name: String?
        public let address: String?
        public init(name: String?, address: String?) { self.name = name; self.address = address }
    }

    public struct Recipient: Decodable {
        public let emailAddress: EmailAddress?
        public init(emailAddress: EmailAddress?) { self.emailAddress = emailAddress }
    }

    /// Graph's `itemBody`: `contentType` is `"html"` or `"text"`.
    public struct ItemBody: Decodable {
        public let contentType: String?
        public let content: String?
        public init(contentType: String?, content: String?) {
            self.contentType = contentType; self.content = content
        }
    }

    public struct Flag: Decodable {
        /// `"notFlagged"`, `"flagged"`, or `"complete"`.
        public let flagStatus: String?
        public init(flagStatus: String?) { self.flagStatus = flagStatus }
    }

    /// Present only on a `delta` response entry for a message that is gone.
    public struct Removed: Decodable {
        public let reason: String?
        public init(reason: String?) { self.reason = reason }
    }

    public let id: String
    /// Graph's server-side thread identity — see `GraphMapping`.
    public let conversationId: String?
    public let internetMessageId: String?
    public let subject: String?
    public let bodyPreview: String?
    public let receivedDateTime: String?
    public let isRead: Bool?
    public let hasAttachments: Bool?
    public let parentFolderId: String?
    public let categories: [String]?
    public let flag: Flag?
    public let from: Recipient?
    public let toRecipients: [Recipient]?
    public let ccRecipients: [Recipient]?
    public let body: ItemBody?
    /// The part of the message that is unique to it, i.e. with the quoted
    /// conversation history removed. Graph only populates this when it is
    /// explicitly `$select`ed.
    public let uniqueBody: ItemBody?
    public let removed: Removed?

    enum CodingKeys: String, CodingKey {
        case id, conversationId, internetMessageId, subject, bodyPreview
        case receivedDateTime, isRead, hasAttachments, parentFolderId, categories
        case flag, from, toRecipients, ccRecipients, body, uniqueBody
        case removed = "@removed"
    }
}

/// A page of `/me/messages` (or of `/me/messages/delta`).
public struct GraphMessageListDTO: Decodable {
    public let value: [GraphMessageDTO]?
    /// The next page of *this* walk. Present on both a plain list and an
    /// unfinished delta walk.
    public let nextLink: String?
    /// Only on the LAST page of a delta walk: the link whose `$deltatoken`
    /// is the cursor for the next sync.
    public let deltaLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }
}

public struct GraphFolderListDTO: Decodable {
    public struct Folder: Decodable {
        public let id: String
        public let displayName: String?
        /// Graph's stable name for a folder the service itself owns
        /// (`inbox`, `archive`, `sentitems`, …). **This, not `displayName`,
        /// is what identifies a system folder** — a mailbox in any non-English
        /// locale, or one whose owner renamed their folders, has arbitrary
        /// display names.
        public let wellKnownName: String?
    }
    public let value: [Folder]?
}

public struct GraphAttachmentDTO: Decodable {
    /// `#microsoft.graph.fileAttachment` for the only kind whose bytes are
    /// inline; item/reference attachments carry no `contentBytes`.
    public let odataType: String?
    public let id: String?
    public let name: String?
    public let contentType: String?
    public let size: Int?
    /// Standard (padded) base64 — NOT base64url, unlike Gmail.
    public let contentBytes: String?

    enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case id, name, contentType, size, contentBytes
    }
}

public struct GraphAttachmentListDTO: Decodable {
    public let value: [GraphAttachmentDTO]?
}

/// `GET /me` — the signed-in user. `mail` is absent for an account with no
/// mailbox address provisioned, in which case `userPrincipalName` is the
/// address Graph itself uses.
public struct GraphProfileDTO: Decodable {
    public let id: String?
    public let mail: String?
    public let userPrincipalName: String?
}
