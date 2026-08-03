import Foundation

/// Pure wire-to-domain mapping. No networking, so every path here is
/// unit-tested directly against recorded fixtures.
public enum GmailMapping {
    /// `dto.messages` arrives in whatever order Gmail's API happens to
    /// return (observed: not reliably oldest-first), and `MailThread.messages`
    /// is documented as oldest-first — every consumer (subject-from-first,
    /// unread counts, etc.) depends on that. Sorting here, rather than trusting
    /// the wire order, is load-bearing.
    public static func thread(_ dto: GmailThreadDTO, accountID: String) -> MailThread {
        let messages = (dto.messages ?? []).map(message).sorted { $0.date < $1.date }
        return MailThread(id: dto.id, accountID: accountID, messages: messages)
    }

    public static func message(_ dto: GmailMessageDTO) -> MailMessage {
        let headers = dto.payload?.headers ?? []
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        // `AddressListParser`, not `split(separator: ",")`: a display name may
        // be a quoted string containing commas, so `"Smith, Bea" <bea@x.com>`
        // used to split into a non-address (`"Smith`, dropped) and a mangled
        // remainder. That silently lost a participant — load-bearing now that
        // reply-all builds its recipients from parsed `To`/`Cc`.
        func addresses(_ name: String) -> [MailAddress] {
            AddressListParser.parse(header(name) ?? "")
        }
        let labels = dto.labelIds ?? []
        let milliseconds = Double(dto.internalDate ?? "0") ?? 0

        return MailMessage(
            id: dto.id,
            threadID: dto.threadId,
            rfc822MessageID: header("Message-ID"),
            from: header("From").flatMap { MailAddress(rfc5322: $0) },
            to: addresses("To"),
            cc: addresses("Cc"),
            subject: header("Subject") ?? "(no subject)",
            date: Date(timeIntervalSince1970: milliseconds / 1000),
            isRead: !labels.contains("UNREAD"),
            isStarred: labels.contains("STARRED"),
            labelIDs: labels,
            hasAttachments: hasAttachment(dto.payload),
            snippet: dto.snippet ?? "",
            attachments: attachments(dto.payload))
    }

    /// Walks `parts` recursively (same shape `hasAttachment`/`body` already
    /// walk) collecting every part that carries an `attachmentId` — Gmail's
    /// own signal that a part's bytes are NOT inlined in this response and
    /// must be fetched separately via `messages.attachments.get`. A part with
    /// no filename (e.g. the text/plain or text/html body part itself) is not
    /// an attachment even if it happens to carry an `attachmentId`.
    private static func attachments(_ payload: GmailMessageDTO.Payload?) -> [MailAttachment] {
        guard let payload else { return [] }
        var results: [MailAttachment] = []
        if let filename = payload.filename, !filename.isEmpty,
           let attachmentID = payload.body?.attachmentId {
            results.append(MailAttachment(
                attachmentID: attachmentID,
                filename: filename,
                mimeType: payload.mimeType ?? "application/octet-stream",
                size: payload.body?.size ?? 0))
        }
        for part in payload.parts ?? [] {
            results.append(contentsOf: attachments(part))
        }
        return results
    }

    /// Prefers `text/plain`; falls back to sanitized `text/html` when no
    /// plain part exists. Walks `parts` recursively since a `multipart/mixed`
    /// message can nest a `multipart/alternative` inside it.
    public static func body(_ dto: GmailMessageDTO) -> MessageBody {
        var plain: String?
        var html: String?
        var ics: String?
        func walk(_ payload: GmailMessageDTO.Payload?) {
            guard let payload else { return }
            let decoded = payload.body?.data.flatMap(decodeBase64URL)
            let mime = payload.mimeType ?? ""
            if mime.hasPrefix("text/plain") { plain = plain ?? decoded }
            else if mime.hasPrefix("text/html") { html = html ?? decoded }
            else if mime.hasPrefix("text/calendar") || mime.hasPrefix("application/ics") {
                ics = ics ?? decoded
            }
            payload.parts?.forEach(walk)
        }
        walk(dto.payload)
        let text = plain ?? html.map(BodySanitizer.plainText(fromHTML:)) ?? ""
        return MessageBody(messageID: dto.id, plainText: text, html: html, icsText: ics)
    }

    public static func labels(_ dto: GmailLabelsDTO) -> [MailLabel] {
        (dto.labels ?? []).map {
            MailLabel(id: $0.id, name: $0.name, kind: $0.type == "system" ? .system : .user)
        }
    }

    /// The inverse of `decodeBase64URL` — Gmail's own encoding, used by
    /// tests to synthesize wire bodies without depending on any real capture.
    public static func base64URL(_ plain: String) -> String {
        Data(plain.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Gmail encodes bodies base64url without padding.
    public static func decodeBase64URL(_ encoded: String) -> String? {
        decodeAttachmentBase64URL(encoded).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Same base64url-without-padding decoding as `decodeBase64URL`, but
    /// returning raw `Data` — for binary attachment bytes, which are not
    /// necessarily valid UTF-8 text.
    public static func decodeAttachmentBase64URL(_ encoded: String) -> Data? {
        var normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        return Data(base64Encoded: normalized)
    }

    private static func hasAttachment(_ payload: GmailMessageDTO.Payload?) -> Bool {
        guard let payload else { return false }
        if let mime = payload.mimeType,
           !mime.hasPrefix("text/"), !mime.hasPrefix("multipart/") { return true }
        return payload.parts?.contains(where: { hasAttachment($0) }) ?? false
    }
}
