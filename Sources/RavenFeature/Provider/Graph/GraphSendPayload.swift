import Foundation

/// The JSON body of `POST /me/messages` — the Graph *message resource* an
/// outgoing message becomes.
///
/// ## Why a JSON payload and not `RFC822Builder`'s output
///
/// Graph offers three send shapes, and the fixtures rule out two of them:
///
/// 1. `POST /me/sendMail` with a JSON `message`. Answers **202 Accepted with an
///    empty body** — no id, ever. At-most-once send is built on a *recorded*
///    success (`SendAttempt`, `OutboxSendOutcome`), so a provider on this shape
///    would have to fabricate the id `MailProvider.send` returns. That is exactly
///    what the read-only period refused to do, and flipping `capabilities` to
///    `.readWrite` must not smuggle it back in.
/// 2. `POST /me/sendMail` with a base64 MIME message (`Content-Type: text/plain`).
///    Same 202, same absent id, and additionally it makes Graph parse a message we
///    assembled rather than assembling it itself.
/// 3. **`POST /me/messages` to create the draft, then `POST
///    /me/messages/{id}/send`.** The first call answers `201` with the created
///    message resource, whose `id` is a real server-minted identifier this
///    provider returns; the second commits it. ★ This is what `GraphMutations.send`
///    does.
///
/// So the body below is a Graph message resource, not RFC 822 — the "third shape"
/// beside Gmail's `raw` upload and SMTP's envelope.
///
/// ## Bcc, and why this shape is safe where Gmail's needs a header
///
/// `RFC822Builder.includeBccHeader` has no default because the right answer
/// depends on how the caller submits: Gmail's `messages/send` derives the envelope
/// from the transmitted headers, so a `Bcc:` header MUST be present or the blind
/// recipient is silently dropped, and Gmail strips it per-copy. SMTP is the
/// opposite — recipients travel in `RCPT TO`, so a transmitted `Bcc:` header would
/// disclose the list to everyone.
///
/// Graph is the SMTP case in JSON clothing. `bccRecipients` is a delivery
/// instruction on the request, sibling to `toRecipients`/`ccRecipients`, and Graph
/// composes each recipient's copy itself — no `Bcc` header is ever transmitted and
/// no other recipient can see the array. `RFC822Builder` is therefore not called
/// on this path at all, and neither value of `includeBccHeader` would be right for
/// it. `GraphSendTests.bccIsADeliveryInstructionAndNotDisclosed` asserts the split
/// on the serialized request body, including that the blind address occurs exactly
/// once in the whole payload.
///
/// ## Known gap, stated rather than hidden
///
/// `inReplyToMessageID` is **not** carried. Graph rejects standard headers in
/// `internetMessageHeaders` (only `x-`-prefixed ones are settable), and its own
/// reply threading runs through `createReply`, which needs the ORIGINAL message's
/// *Graph* id — `OutgoingMessage.inReplyToMessageID` is an RFC 822 `Message-ID`,
/// which is not that. So a reply sent from a Graph account is delivered correctly
/// but arrives unthreaded in the recipient's client. Fabricating a header Graph
/// would reject would fail the whole send instead.
enum GraphSendPayload {
    /// The draft-creation body for `message`, ready for `JSONSerialization`.
    ///
    /// All three recipient arrays are always present, even when empty: an omitted
    /// key and an empty array are the same thing to Graph, but a test asserting a
    /// *split* needs the absence of an address from an array it can actually see.
    static func draft(for message: OutgoingMessage) -> [String: Any] {
        var payload: [String: Any] = [
            "subject": message.subject,
            "body": ["contentType": "html", "content": html(for: message)],
            "toRecipients": recipients(message.to),
            "ccRecipients": recipients(message.cc),
            "bccRecipients": recipients(message.bcc),
        ]
        let files = attachments(for: message)
        if !files.isEmpty { payload["attachments"] = files }
        return payload
    }

    /// One Graph `recipient`, which nests the address inside an `emailAddress`
    /// object. `name` is omitted when there is none rather than defaulting to the
    /// address, so a payload never invents a display name the user did not type.
    private static func recipients(_ addresses: [MailAddress]) -> [[String: Any]] {
        addresses.map { address in
            var email: [String: Any] = ["address": address.email]
            if let name = address.name, !name.isEmpty { email["name"] = name }
            return ["emailAddress": email]
        }
    }

    /// The HTML body, rendered by exactly the renderers `RFC822Builder` uses and
    /// chosen on exactly the same condition — whether the composer recorded
    /// formatting — so a message sent from a Graph account reads the same as the
    /// same message sent from a Gmail or IMAP one.
    ///
    /// Only the HTML part is sent: a Graph message resource has ONE `body`, not a
    /// `multipart/alternative` pair, and Graph generates the text alternative for
    /// clients that need it. Sending `contentType: "text"` instead would throw the
    /// formatting away.
    private static func html(for message: OutgoingMessage) -> String {
        let plainText = message.richBody?.plainText ?? message.bodyText
        let rendered: String
        if let rich = message.richBody {
            rendered = RichBodyHTML.renderComposed(rich)
        } else {
            rendered = MarkdownToHTML.renderComposed(message.bodyText)
        }
        // Same base-direction wrapper, for the same reason and detected on the
        // same string as in `RFC822Builder`: an Arabic message inside an
        // implicitly `ltr` document has every paragraph flush to the wrong side.
        // Emitted only for `rtl`, so an English body is byte-identical to the
        // renderer's own output.
        switch BaseTextDirection.detect(plainText) {
        case .leftToRight: return rendered
        case .rightToLeft: return "<div dir=\"rtl\">\(rendered)</div>"
        }
    }

    /// File attachments plus, when present, the calendar reply as one more file
    /// part — the same "never in place of the human-readable body" rule
    /// `RFC822Builder` follows, so a client with no calendar support still shows
    /// the message.
    ///
    /// `contentBytes` is **standard padded base64, not base64url**: that is what
    /// Graph's `fileAttachment` takes, and it is the same asymmetry with Gmail that
    /// `GraphProvider.fetchAttachment` documents on the way in.
    private static func attachments(for message: OutgoingMessage) -> [[String: Any]] {
        var parts: [[String: Any]] = message.attachments.map { attachment in
            [
                "@odata.type": "#microsoft.graph.fileAttachment",
                "name": attachment.filename,
                "contentType": attachment.mimeType,
                "contentBytes": attachment.data.base64EncodedString(),
            ]
        }
        if let reply = message.icsReply {
            parts.append([
                "@odata.type": "#microsoft.graph.fileAttachment",
                "name": "invite.ics",
                "contentType": "text/calendar; method=REPLY",
                "contentBytes": Data(reply.icsText.utf8).base64EncodedString(),
            ])
        }
        return parts
    }
}
