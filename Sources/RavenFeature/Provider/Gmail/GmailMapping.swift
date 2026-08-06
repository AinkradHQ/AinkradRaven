import Foundation

/// Pure wire-to-domain mapping. No networking, so every path here is
/// unit-tested directly against recorded fixtures.
public enum GmailMapping {
    /// Gmail's canonical-flag translation. The identity mapping, so reading
    /// through it is behaviour-identical to the label-literal comparisons this
    /// mapper used to do inline.
    static let vocabulary = GmailVocabulary()

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
            // Read through Gmail's own vocabulary — the identity mapping — so
            // the literals live in exactly one place. Labels are still STORED
            // below as Gmail's strings; nothing about the document changes.
            isRead: !vocabulary.flags(from: labels).contains(.unread),
            isStarred: vocabulary.flags(from: labels).contains(.starred),
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
        return MessageBody(messageID: dto.id, plainText: text, html: html, icsText: ics,
                           signatureStatus: signatureStatus(dto.payload))
    }

    /// `.unsigned` unless `payload` is a two-child `multipart/signed`
    /// entity — Gmail's own signal for "this arrived as `multipart/signed;
    /// protocol=\"application/pkcs7-signature\"`". When it is, and the
    /// signed-content child is itself a LEAF part (its bytes are directly in
    /// `body.data`, not decomposed into further `parts` the way a
    /// `multipart/*` signed body is), the exact canonical bytes Gmail handed
    /// back — that child's own raw `Content-Type` header line plus its
    /// decoded body — are re-verified against the sibling `application/
    /// pkcs7-signature` part via `SMIME.verify`.
    ///
    /// A signed-content child that is ITSELF `multipart/*` cannot be
    /// reconstructed byte-for-byte from Gmail's already-decomposed JSON (the
    /// original multipart body text, its exact boundary framing and
    /// `Content-Transfer-Encoding`s, is not preserved once Gmail's API has
    /// parsed it into `parts`) — that case is reported `.signedInvalid`
    /// rather than silently `.unsigned`: a signature Gmail says is present
    /// but this mapping cannot verify must never look identical to "no
    /// signature at all".
    private static func signatureStatus(_ payload: GmailMessageDTO.Payload?) -> SignatureStatus {
        guard let payload, (payload.mimeType ?? "").hasPrefix("multipart/signed"),
              let children = payload.parts, children.count == 2 else {
            return .unsigned
        }
        func isSignaturePart(_ part: GmailMessageDTO.Payload) -> Bool {
            (part.mimeType ?? "").hasPrefix("application/pkcs7-signature")
                || (part.mimeType ?? "").hasPrefix("application/x-pkcs7-signature")
        }
        guard let signaturePart = children.first(where: isSignaturePart),
              let contentPart = children.first(where: { !isSignaturePart($0) }),
              let signatureEncoded = signaturePart.body?.data,
              let signature = decodeAttachmentBase64URL(signatureEncoded) else {
            return .signedInvalid
        }
        // A `multipart/*` signed-content child cannot be canonicalized from
        // Gmail's decomposed JSON — see the doc comment above.
        guard contentPart.parts == nil || contentPart.parts?.isEmpty == true,
              let bodyEncoded = contentPart.body?.data,
              let decodedBody = decodeAttachmentBase64URL(bodyEncoded) else {
            return .signedInvalid
        }
        let contentTypeHeader = contentPart.headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value ?? contentPart.mimeType ?? ""
        let canonical = Data("Content-Type: \(contentTypeHeader)\r\n\r\n".utf8) + decodedBody
        return SMIME.verify(signedContent: canonical, signature: signature)
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
