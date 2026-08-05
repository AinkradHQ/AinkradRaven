import Foundation

/// An `ENVELOPE`, RFC 3501 §7.4.2, as domain values.
///
/// `date` is kept as the RAW string alongside the parsed `parsedDate` on
/// purpose: an unparseable date must not drop the message (see
/// `IMAPFetchParser.message`), and keeping the original is what lets a caller
/// tell "the server sent no date" from "the server sent something this build
/// cannot read" — the second is a parser gap worth logging, the first is not.
struct IMAPEnvelope: Equatable, Sendable {
    let rawDate: String?
    let parsedDate: Date?
    /// Already RFC 2047-decoded. `nil` when the server sent `NIL`.
    let subject: String?
    let from: [MailAddress]
    let sender: [MailAddress]
    let replyTo: [MailAddress]
    let to: [MailAddress]
    let cc: [MailAddress]
    let bcc: [MailAddress]
    /// Angle brackets stripped, matching `RFC822Message.messageID` and what
    /// `LocalThreading` compares.
    let inReplyTo: String?
    let messageID: String?
}

/// Everything one `* <n> FETCH (…)` line carried.
///
/// A record of the wire, not yet a `MailMessage`: message *identity* (the id a
/// `MailMessage` is keyed by, and its thread id) is deliberately NOT decided
/// here. Thread ids come from `LocalThreading` over `Message-ID`/`References`
/// and message ids must not be a bare UID, which is mailbox-local and can be
/// invalidated by a `UIDVALIDITY` change. Both are Task 13's business, so
/// `message(_:id:threadID:)` takes them as arguments.
struct IMAPFetchResponse: Equatable, Sendable {
    let sequenceNumber: UInt64
    let uid: UInt64?
    /// Canonical flags. See `IMAPFetchParser.canonicalFlags` for the mapping and
    /// for why no raw IMAP flag string escapes this layer.
    let flags: Set<MailFlag>
    let internalDate: Date?
    let rfc822Size: Int?
    let envelope: IMAPEnvelope?
    let bodyStructure: IMAPBodyPart?
    /// The bytes of a `BODY[HEADER.FIELDS (…)]` / `BODY[HEADER]` section.
    let headerFields: Data?
    /// Fetched body sections keyed by their specifier, uppercased: `"TEXT"`,
    /// `"1"`, `"2.1"`, `""` for `BODY[]`. Empty when the fetch asked for
    /// structure only, which is the normal case — bytes are fetched on demand.
    let sections: [String: Data]
}

/// Turns an untagged `FETCH` response's tokens into domain models.
///
/// ## Attribution: no response router, and why that is correct *here*
///
/// `IMAPSession` attributes untagged lines to a command only when exactly one
/// command is in flight (`IMAPSession.execute`'s doc comment states this), and
/// untagged `FETCH` data genuinely carries no tag, so a pipelined FETCH's data
/// cannot be attributed. This task does not need a mailbox-scoped router,
/// because **nothing here issues a command**: it is a pure function from tokens
/// to values, and every one of its tests drives it from recorded bytes. The
/// constraint it imposes on the eventual caller is stated once, here, since this
/// is the only place in the tree that knows what FETCH data is:
///
/// > A command whose untagged `FETCH` data you intend to read must be the only
/// > command in flight for the duration. Read `IMAPTaggedResponse.untagged`,
/// > which is exactly the set the session could attribute unambiguously; do not
/// > reconstruct it from the global `untaggedResponses` stream, which interleaves
/// > every mailbox.
///
/// That is a MECHANISM, not a rule to remember: mark the command
/// `IMAPCommand.isExclusive` and `IMAPSession.requireChannelAdmits` enforces sole
/// occupancy at the channel — a second command is refused with
/// `channelReserved` rather than quietly costing you your untagged data.
///
/// The mechanism is *sufficient* for Tasks 12 and 13 and inadequate for Task 14.
/// `IDLE` holds a command in flight indefinitely, and the window that
/// mis-attributes is IDLE **alone** in flight: its record is then the sole one,
/// so every mailbox's untagged line is appended to it. (With IDLE *plus* a FETCH
/// the count is 2 and neither is attributed — data is lost rather than
/// misfiled.) Either way a mailbox-scoped router becomes load-bearing there, not
/// merely tidier. Building it now would be speculative — it would have no second
/// consumer to be shaped by — so it is left to the task that first cannot work
/// without it.
enum IMAPFetchParser {

    // MARK: - Line parsing

    /// Parses one untagged response. Returns `nil` — rather than throwing — when
    /// the line is simply not a `FETCH`, because a caller draining a mixed
    /// untagged stream (`EXISTS`, `OK`, `FLAGS`) must be able to skip
    /// uninteresting lines without treating them as errors.
    static func parse(_ response: IMAPUntaggedResponse) throws -> IMAPFetchResponse? {
        var reader = IMAPValueReader(response.tokens)
        guard case .number(let sequenceNumber)? = reader.peek() else { return nil }
        reader.advance()
        guard let keyword = reader.peek()?.stringValue?.uppercased(), keyword == "FETCH" else {
            return nil
        }
        reader.advance()
        guard reader.consume(.listOpen) else { throw IMAPFetchParseError.notAFetchResponse }
        return try parseItems(&reader, sequenceNumber: sequenceNumber)
    }

    private static func parseItems(_ reader: inout IMAPValueReader,
                                   sequenceNumber: UInt64) throws -> IMAPFetchResponse {
        var uid: UInt64?
        var flags: Set<MailFlag> = []
        var arrivalDate: Date?
        var size: Int?
        var envelope: IMAPEnvelope?
        var structure: IMAPBodyPart?
        var headerFields: Data?
        var sections: [String: Data] = [:]

        while true {
            guard let token = reader.peek() else { throw IMAPFetchParseError.truncated }
            if token == .listClose { reader.advance(); break }
            guard let name = token.stringValue?.uppercased() else {
                throw IMAPFetchParseError.unexpectedToken(token.description)
            }
            reader.advance()
            // A bracket after the item name means a section specifier, whatever
            // the name was (`BODY[…]`, `BINARY[…]`). Deciding on the bracket
            // rather than on the name is what keeps an unknown-but-sectioned
            // item from derailing the whole line.
            if reader.peek() == .bracketOpen {
                let (key, payload) = try parseSection(&reader)
                if key.hasPrefix("HEADER") {
                    headerFields = payload ?? headerFields
                } else if let payload {
                    sections[key] = payload
                }
                continue
            }
            let value = try reader.readValue()
            switch name {
            case "UID":
                if case .number(let parsed) = value { uid = parsed }
            case "FLAGS":
                flags = canonicalFlags(from: (value.listValue ?? []).compactMap(\.stringValue))
            case "INTERNALDATE":
                arrivalDate = value.stringValue.flatMap(internalDate(from:))
            case "RFC822.SIZE":
                size = value.intValue
            case "ENVELOPE":
                envelope = parseEnvelope(value)
            case "BODYSTRUCTURE", "BODY":
                structure = try IMAPBodyPart.parse(value)
            default:
                // Unknown item: its value has been consumed, so the rest of the
                // line still parses. Tolerance here is deliberate — servers send
                // items we never asked for (`MODSEQ`, vendor extensions).
                break
            }
        }
        return IMAPFetchResponse(
            sequenceNumber: sequenceNumber, uid: uid, flags: flags,
            internalDate: arrivalDate, rfc822Size: size, envelope: envelope,
            bodyStructure: structure, headerFields: headerFields, sections: sections)
    }

    /// Consumes `[…]`, an optional `<offset>`, and the section's value.
    /// The key is the specifier's first token uppercased — `TEXT`,
    /// `HEADER.FIELDS`, `1`, `2.1`, or `""` for the whole-message `BODY[]`.
    private static func parseSection(
        _ reader: inout IMAPValueReader) throws -> (String, Data?) {
        guard reader.consume(.bracketOpen) else { throw IMAPFetchParseError.truncated }
        var key: String?
        var depth = 0
        while true {
            guard let token = reader.peek() else { throw IMAPFetchParseError.truncated }
            reader.advance()
            switch token {
            case .bracketClose where depth == 0:
                // A partial-fetch `<offset>` lexes as one atom, because `<` is
                // not a lexer delimiter. Skip it; the offset does not change
                // which section this is.
                // Matched as an ATOM specifically: a literal whose first byte
                // happens to be `<` (an HTML body part) must not be mistaken
                // for an offset and skipped, which would drop the payload.
                if case .atom(let text)? = reader.peek(), text.hasPrefix("<") {
                    reader.advance()
                }
                let value = try reader.readValue()
                return (key ?? "", value.isNil ? nil : value.dataValue)
            case .listOpen: depth += 1
            case .listClose: depth -= 1
            default:
                if depth == 0, key == nil { key = token.stringValue?.uppercased() }
            }
        }
    }

    // MARK: - ENVELOPE

    private static func parseEnvelope(_ value: IMAPValue) -> IMAPEnvelope? {
        guard let items = value.listValue else { return nil }
        func field(_ index: Int) -> IMAPValue? {
            index < items.count ? items[index] : nil
        }
        func addresses(_ index: Int) -> [MailAddress] {
            (field(index)?.listValue ?? []).compactMap(address)
        }
        let rawDate = field(0)?.stringValue
        // RFC 2047 on the subject: a non-ASCII subject arrives as
        // `=?UTF-8?B?…?=` and is otherwise shown to the user verbatim as that
        // gibberish. `nil` stays `nil` — a NIL subject is not an empty subject.
        let subject = field(1)?.stringValue.map(RFC2047.decode)
        return IMAPEnvelope(
            rawDate: rawDate,
            parsedDate: rawDate.flatMap(RFC822Message.date(rfc822:)),
            subject: subject,
            from: addresses(2), sender: addresses(3), replyTo: addresses(4),
            to: addresses(5), cc: addresses(6), bcc: addresses(7),
            inReplyTo: field(8)?.stringValue.map(stripAngleBrackets),
            messageID: field(9)?.stringValue.map(stripAngleBrackets))
    }

    /// One `(name adl mailbox host)` address structure. A group marker (host
    /// `NIL`) yields no address rather than a bogus `name@nil`.
    private static func address(_ value: IMAPValue) -> MailAddress? {
        guard let items = value.listValue, items.count >= 4 else { return nil }
        guard let mailbox = items[2].stringValue, let host = items[3].stringValue,
              !mailbox.isEmpty, !host.isEmpty else { return nil }
        let name = items[0].stringValue.map(RFC2047.decode)
        return MailAddress(email: "\(mailbox)@\(host)",
                           name: (name?.isEmpty ?? true) ? nil : name)
    }

    private static func stripAngleBrackets(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    // MARK: - FLAGS

    /// IMAP flags → Task 2's canonical `MailFlag` vocabulary.
    ///
    /// Two properties are deliberate. First, the polarity: IMAP stores `\Seen`
    /// while the domain stores `unread`, so the ABSENCE of `\Seen` is what emits
    /// `.unread` — that is exactly why `MailFlag` chose the unread polarity.
    /// Second, **no raw IMAP flag string is ever returned**. `\Answered` and
    /// `\Recent` have no canonical meaning and are dropped rather than smuggled
    /// through as `.user("\\Answered")`, which would put an IMAP spelling into a
    /// domain that the whole point of Task 2 was to keep provider-neutral. A
    /// server *keyword* (no leading backslash, e.g. `$Important`) is a real user
    /// label and does come through as `.user`.
    static func canonicalFlags(from imapFlags: [String]) -> Set<MailFlag> {
        var flags: Set<MailFlag> = []
        var sawSeen = false
        for flag in imapFlags {
            switch flag.lowercased() {
            case "\\seen": sawSeen = true
            case "\\flagged": flags.insert(.starred)
            // `\Deleted` is IMAP's "marked for expunge". `.trash` is the
            // canonical flag that means the same thing to the domain; the
            // folder-move mechanics (`UID MOVE` to the trash mailbox) are Task
            // 13's, and they read this flag rather than a raw string.
            case "\\deleted": flags.insert(.trash)
            case "\\draft": flags.insert(.draft)
            case "\\answered", "\\recent": break
            default:
                guard !flag.hasPrefix("\\"), !flag.isEmpty else { break }
                flags.insert(.user(flag))
            }
        }
        if !sawSeen { flags.insert(.unread) }
        return flags
    }

    /// `INTERNALDATE`'s own syntax (RFC 3501 §9 `date-time`), which is NOT the
    /// RFC 2822 form `ENVELOPE`'s date uses: `"17-Jul-1996 02:44:25 -0700"`,
    /// with the day-of-month possibly space-padded.
    static func internalDate(from raw: String) -> Date? {
        internalDateFormatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    private static let internalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()

    // MARK: - Domain mapping

    /// The date a message is shown and sorted by, and the reason an unparseable
    /// one cannot drop the message.
    ///
    /// `MailMessage.date` is non-optional, so a `nil` here would have to become
    /// a dropped message — silently losing mail because one server wrote a date
    /// this build's formatters do not accept. The ladder is: the envelope's
    /// `Date:`, then `INTERNALDATE` (the server's own arrival time, always
    /// well-formed since the server generated it), then the epoch. The message
    /// survives every rung.
    static func date(_ response: IMAPFetchResponse) -> Date {
        response.envelope?.parsedDate
            ?? response.internalDate
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Builds the domain message. `id` and `threadID` are the caller's (Task
    /// 13's) to choose — see `IMAPFetchResponse`.
    ///
    /// `labelIDs` is deliberately left empty. `MailMessage.labelIDs` stores the
    /// *provider's* strings for round-tripping mutations, and for IMAP those are
    /// mailbox names, which a single `FETCH` line does not know — the mailbox is
    /// the `SELECT`ed context, mapped by Task 11's `IMAPMailbox`. Writing IMAP
    /// flag strings here instead would be exactly the leak Task 2 removed.
    /// `flags` carries the canonical reading for anyone who needs it.
    static func message(_ response: IMAPFetchResponse,
                        id: String, threadID: String) -> MailMessage {
        let envelope = response.envelope
        let attachments = response.bodyStructure?.attachments ?? []
        // Matches `GmailMapping.message`'s fallback so an empty-subject message
        // reads the same in both providers' lists.
        let subject = envelope?.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
        return MailMessage(
            id: id,
            threadID: threadID,
            rfc822MessageID: envelope?.messageID,
            from: envelope?.from.first,
            to: envelope?.to ?? [],
            cc: envelope?.cc ?? [],
            subject: subject,
            date: date(response),
            isRead: !response.flags.contains(.unread),
            isStarred: response.flags.contains(.starred),
            labelIDs: [],
            hasAttachments: !attachments.isEmpty,
            snippet: "",
            attachments: attachments)
    }

    /// Builds the body from the structure plus whatever sections were fetched.
    ///
    /// The `html` field carries the ORIGINAL HTML and `plainText` carries
    /// `BodySanitizer`'s reduction of it — identical to `GmailMapping.body`, and
    /// that identity is the point. `BodySanitizer.plainText(fromHTML:)` is the
    /// only sanitizer this codebase has: it produces plain TEXT, whose contract
    /// (`ThreadSurface`) is that it is never re-rendered as HTML. Storing that
    /// text in `html` would both break "Show original" — the raw-HTML pane would
    /// render already-sanitized text as markup, the one thing the guarantee
    /// forbids — and make IMAP disagree with Gmail for the same message. So HTML
    /// reaches `MessageBody` only *through* `BodySanitizer`, on the plainText
    /// path, exactly as every other provider does it.
    static func body(_ response: IMAPFetchResponse, messageID: String) -> MessageBody {
        let structure = response.bodyStructure
        // `BODY[TEXT]` means "the whole MIME body", which is the same bytes as
        // part 1 ONLY for a single-part message. In a multipart it is the entire
        // body including boundary delimiters and per-part headers, so letting
        // part 1 fall back to it would put raw MIME into `plainText`.
        let isSinglePart = structure?.children.isEmpty == true
        func partText(_ part: IMAPBodyPart) -> String? {
            text(of: part, in: response, allowsWholeBodyFallback: isSinglePart)
        }
        let plain = structure?.plainTextPart.flatMap(partText)
        let html = structure?.htmlPart.flatMap(partText)
        let ics = structure?.calendarPart.flatMap(partText)
        let body = plain ?? html.map(BodySanitizer.plainText(fromHTML:)) ?? ""
        return MessageBody(messageID: messageID, plainText: body, html: html, icsText: ics)
    }

    /// A part's decoded text, if its bytes were fetched.
    ///
    /// A single-part message is normally fetched as `BODY[TEXT]` (the part number
    /// `1` never appears in that response), so `allowsWholeBodyFallback` lets
    /// part 1 read those keys. It must be false for a multipart — see `body`.
    private static func text(of part: IMAPBodyPart, in response: IMAPFetchResponse,
                             allowsWholeBodyFallback: Bool) -> String? {
        var payload = part.partNumber.flatMap { response.sections[$0] }
        if payload == nil, allowsWholeBodyFallback, part.partNumber == "1" {
            payload = response.sections["TEXT"] ?? response.sections[""]
        }
        guard let payload else { return nil }
        let decoded = RFC822Message.decodeTransferEncoding(payload, encoding: part.encoding)
        return String(data: decoded, encoding: .utf8)
            ?? String(data: decoded, encoding: .isoLatin1)
    }

    /// The `References`/`In-Reply-To` view of a fetched `BODY[HEADER.FIELDS …]`
    /// section, decoded by `RFC822Message` — the existing tolerant header
    /// parser, folding and all — rather than a second one written here.
    /// `LocalThreading` (Task 13) is the consumer.
    static func headers(_ response: IMAPFetchResponse) -> RFC822Message? {
        response.headerFields.map(RFC822Message.parse)
    }
}
