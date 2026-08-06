import Foundation

/// Why a `FETCH` response could not be shaped into values. Typed, for the same
/// reason `IMAPLexerError` is: the input is a remote server, so "malformed" must
/// be a value a session can log and fail a command with.
enum IMAPFetchParseError: Error, Equatable {
    /// A token appeared where the grammar allows only a value (a stray `]`, a
    /// CRLF inside a list, a `)` with no matching `(`).
    case unexpectedToken(String)
    /// The token stream ended mid-construct. Distinct from `unexpectedToken`
    /// because it means "the caller handed us a partial line", which is a
    /// framing bug upstream rather than a malformed server.
    case truncated
    /// The line is not `<n> FETCH (…)`.
    case notAFetchResponse
    /// A `BODYSTRUCTURE` was present but could not be shaped into a part tree.
    /// Distinct from a *missing* structure (`BODYSTRUCTURE NIL`), which is not an
    /// error: the point of the distinction is that a malformed structure must
    /// never be silently rounded down to a plausible-looking one.
    case malformedBodyStructure(String)
}

/// A value tree over `IMAPToken`s.
///
/// `IMAPLexer` is deliberately flat — it emits `listOpen`/`listClose` rather
/// than nesting — because being flat is what makes it resumable. Nesting is
/// this layer's job, and it happens *only* over tokens: literal bytes arrive
/// already carved out by the lexer as `.literal` and are never re-scanned here.
/// That is the same opacity contract the lexer documents, held one level up.
indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case number(UInt64)
    /// `NIL`. Kept distinct from `.string("NIL")` — a subject that is literally
    /// the text `NIL` must not read as a missing subject.
    case nilValue
    /// A quoted string, unescaped.
    case string(String)
    /// A `{n}` literal's opaque bytes.
    case data(Data)
    case list([IMAPValue])

    /// The text of a value that carries one. `nil` for `NIL` and for lists, so a
    /// caller cannot silently read a missing value as an empty string.
    var stringValue: String? {
        switch self {
        case .atom(let value), .string(let value): return value
        case .number(let value): return String(value)
        case .data(let data):
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        case .nilValue, .list: return nil
        }
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    var dataValue: Data? {
        switch self {
        case .data(let data): return data
        case .atom(let text), .string(let text): return Data(text.utf8)
        case .number(let value): return Data(String(value).utf8)
        case .nilValue, .list: return nil
        }
    }

    var listValue: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }
}

/// A cursor over a token line that builds `IMAPValue`s on demand.
///
/// A cursor rather than a whole-line tree builder because a `FETCH` line is not
/// purely a value tree: `BODY[HEADER.FIELDS (…)]` mixes bracketed *section
/// specifiers* into the item list, and those are grammar, not values. The
/// parser therefore drives the token stream itself and asks this reader only
/// for the value positions.
struct IMAPValueReader {
    private let tokens: [IMAPToken]
    private(set) var position: Int

    init(_ tokens: [IMAPToken], from position: Int = 0) {
        self.tokens = tokens
        self.position = position
    }

    var isAtEnd: Bool { position >= tokens.count }

    func peek() -> IMAPToken? { position < tokens.count ? tokens[position] : nil }

    mutating func advance() { position += 1 }

    /// Consumes `token` if it is next; returns whether it did.
    mutating func consume(_ token: IMAPToken) -> Bool {
        guard peek() == token else { return false }
        position += 1
        return true
    }

    /// Reads one complete value, recursing into lists.
    mutating func readValue() throws -> IMAPValue {
        guard let token = peek() else { throw IMAPFetchParseError.truncated }
        position += 1
        switch token {
        case .atom(let text): return .atom(text)
        case .number(let value): return .number(value)
        case .nilValue: return .nilValue
        case .quoted(let text): return .string(text)
        case .literal(let data): return .data(data)
        case .listOpen:
            var items: [IMAPValue] = []
            while true {
                guard let next = peek() else { throw IMAPFetchParseError.truncated }
                if next == .listClose {
                    position += 1
                    return .list(items)
                }
                items.append(try readValue())
            }
        case .listClose, .bracketOpen, .bracketClose, .endOfLine:
            throw IMAPFetchParseError.unexpectedToken(token.description)
        }
    }
}

/// One MIME entity from a `BODYSTRUCTURE`, with its IMAP part number.
///
/// **Metadata only, deliberately.** No part carries bytes. M0's contract is that
/// attachment bytes are fetched on demand (`MailProvider.fetchAttachment`), and
/// the part number here is exactly the handle a later `UID FETCH … BODY[<n>]`
/// needs. A `BODYSTRUCTURE` walk that also downloaded bodies would make opening
/// a mailbox cost every attachment in it.
struct IMAPBodyPart: Equatable, Sendable {
    /// The IMAP part number (`"1"`, `"2.1"`). `nil` for the top-level
    /// `multipart/*` entity itself, which RFC 3501 does not number — only its
    /// children are addressable.
    let partNumber: String?
    /// Lowercased `type/subtype`, e.g. `text/plain`, `multipart/alternative`.
    let mimeType: String
    /// Content-Type parameters, keys lowercased.
    let parameters: [String: String]
    /// `Content-Transfer-Encoding`, lowercased. `nil` for multiparts.
    let encoding: String?
    /// The part's octet count as the server reported it. `nil` for multiparts,
    /// which report no size.
    let size: Int?
    /// Lowercased `Content-Disposition` type (`inline`, `attachment`).
    let dispositionType: String?
    /// Disposition `filename`, falling back to the Content-Type `name`
    /// parameter — the older spelling, still emitted by real servers.
    let filename: String?
    let children: [IMAPBodyPart]

    var isMultipart: Bool { mimeType.hasPrefix("multipart/") }

    /// Depth-first pre-order: this part, then each child's own walk.
    ///
    /// The order is load-bearing, not incidental. `GmailMapping.body` walks
    /// Gmail's already-decomposed part tree in exactly this order and takes the
    /// FIRST `text/plain` and FIRST `text/html` it meets anywhere in the tree.
    /// Matching that walk is what makes the two providers agree on the
    /// plain/HTML pair for a `multipart/alternative` nested inside a
    /// `multipart/mixed`, which `IMAPFetchParserTests` asserts directly.
    var preOrder: [IMAPBodyPart] {
        [self] + children.flatMap(\.preOrder)
    }

    /// The first `text/plain` part in pre-order, if any.
    var plainTextPart: IMAPBodyPart? {
        preOrder.first { $0.mimeType.hasPrefix("text/plain") }
    }

    var htmlPart: IMAPBodyPart? {
        preOrder.first { $0.mimeType.hasPrefix("text/html") }
    }

    var calendarPart: IMAPBodyPart? {
        preOrder.first {
            $0.mimeType.hasPrefix("text/calendar") || $0.mimeType.hasPrefix("application/ics")
        }
    }

    /// Whether the message should show a paperclip — deliberately a LOOSER test
    /// than `attachments`, and matching `GmailMapping.hasAttachment` exactly: any
    /// part that is neither `text/*` nor `multipart/*`.
    ///
    /// The two must differ. `attachments` requires a filename because the UI cannot
    /// offer to save a file it has no name for, but Gmail's paperclip does not:
    /// an unnamed inline `image/png` (which every HTML newsletter carries, and
    /// which `Content-Disposition: inline` with no `filename` is the normal
    /// spelling of) makes Gmail answer true. Deriving `hasAttachments` from
    /// `!attachments.isEmpty` therefore made the SAME message show a paperclip in a
    /// Gmail account and none in an IMAP account — a divergence with no defensible
    /// reading, since the flag means "there is more here than text".
    var carriesAttachment: Bool {
        preOrder.contains { part in
            !part.mimeType.hasPrefix("text/") && !part.mimeType.hasPrefix("multipart/")
        }
    }

    /// Attachment *metadata* for every named leaf part.
    ///
    /// "Named" is the test, matching `GmailMapping.attachments`, which requires a
    /// non-empty filename: the `text/plain` and `text/html` body parts of an
    /// alternative are not attachments even though they are leaves, and a part
    /// the server marked `attachment` with no filename at all is not something
    /// the UI can offer to save. `attachmentID` is the part number, which is the
    /// on-demand fetch handle.
    ///
    /// Not the same question as `carriesAttachment` — see that property.
    var attachments: [MailAttachment] {
        preOrder.compactMap { part in
            guard !part.isMultipart, let number = part.partNumber,
                  let filename = part.filename, !filename.isEmpty else { return nil }
            return MailAttachment(attachmentID: number, filename: filename,
                                  mimeType: part.mimeType, size: part.size ?? 0)
        }
    }
}

extension IMAPBodyPart {
    /// Shapes a `BODYSTRUCTURE` value into a numbered part tree.
    ///
    /// RFC 3501 §7.4.2 gives multiparts away by shape, not by a keyword: a
    /// multipart body is a sequence of nested part *lists* followed by the
    /// subtype string, while a single part starts with the type string. So the
    /// discriminator is "is the first element a list", which is also why this
    /// cannot be driven off `mimeType` — the type is not known until after the
    /// branch is chosen.
    /// `nil` — not an error — when the server sent `BODYSTRUCTURE NIL`, i.e. no
    /// structure at all. A structure that is present but *malformed* throws, so a
    /// garbage `mimeType` is never manufactured out of a misread list.
    static func parse(_ value: IMAPValue) throws -> IMAPBodyPart? {
        guard let items = value.listValue, !items.isEmpty else { return nil }
        let part = items[0].listValue == nil
            ? try parseSinglePart(items) : try parseMultipart(items)
        return part.numbered(prefix: nil)
    }

    private static func parseSinglePart(_ items: [IMAPValue]) throws -> IMAPBodyPart {
        guard let type = items[0].stringValue else {
            throw IMAPFetchParseError.malformedBodyStructure("part type is not a string")
        }
        let subtype = items.count > 1 ? (items[1].stringValue ?? "") : ""
        let parameters = items.count > 2 ? parseParameters(items[2]) : [:]
        let encoding = items.count > 5 ? items[5].stringValue?.lowercased() : nil
        let size = items.count > 6 ? items[6].intValue : nil
        // Extension fields follow the required ones and are position-dependent
        // per RFC 3501 §7.4.2, so the disposition's index depends on the part's
        // TYPE. Reading the wrong slot does not fail loudly — it reads whatever
        // happens to be there — so each of the three shapes is spelled out:
        //
        //   body-type-basic (8): …enc, octets, md5, DSP
        //   body-type-text  (9): …enc, octets, LINES, md5, DSP
        //   body-type-msg  (11): …enc, octets, ENVELOPE, BODY, LINES, md5, DSP
        //
        // `message/rfc822` is the one that bites: index 8 is the nested
        // BODYSTRUCTURE *list*, so reading the disposition there yields a
        // nonsense `dispositionType` and substitutes the Content-Type `name` for
        // the disposition filename — a forwarded `.eml` that either stops being
        // an attachment or keeps a plausible WRONG name. Forwarded messages are
        // common.
        //
        // The nested envelope/body at indices 7/8 are deliberately NOT
        // decomposed — this part stays opaque, and its bytes are fetched on
        // demand like any other attachment.
        //
        // The subtype is part of the discriminator, not decoration. RFC 3501's
        // `media-message` is `"MESSAGE" SP "RFC822"` and nothing else, so
        // `body-type-msg` — and its index 11 — applies to that one subtype.
        // Every other `message/*` (`DELIVERY-STATUS`, `PARTIAL`,
        // `DISPOSITION-NOTIFICATION`) is a `body-type-basic` with its DSP at 8,
        // and bounce notifications carry `message/delivery-status` routinely.
        // Switching on the type alone would misparse them in exactly the shape
        // the `rfc822` fix exists to prevent, one subtype over.
        let dispositionIndex: Int
        switch (type.lowercased(), subtype.lowercased()) {
        case ("text", _): dispositionIndex = 9
        case ("message", "rfc822"): dispositionIndex = 11
        default: dispositionIndex = 8
        }
        let disposition = items.count > dispositionIndex
            ? parseDisposition(items[dispositionIndex]) : (nil, nil)
        let mimeType = "\(type.lowercased())/\(subtype.lowercased())"
        return IMAPBodyPart(
            partNumber: nil, mimeType: mimeType, parameters: parameters,
            encoding: encoding, size: size,
            dispositionType: disposition.0,
            filename: disposition.1 ?? parameters["name"],
            children: [])
    }

    private static func parseMultipart(_ items: [IMAPValue]) throws -> IMAPBodyPart {
        var children: [IMAPBodyPart] = []
        var index = 0
        while index < items.count, let nested = items[index].listValue {
            // A nested part list is itself either single or multi, decided the
            // same way. A child that will not parse THROWS rather than ending the
            // loop: `break` would silently drop that child and every sibling
            // after it, and — worse — leave `index` pointing at a part LIST, so
            // the subtype/parameter reads below would land on it and manufacture
            // a garbage `mimeType` from a nested part's type string. An error a
            // session can log beats a body tree that looks plausible.
            guard nested.first != nil else {
                throw IMAPFetchParseError.malformedBodyStructure("empty nested part list")
            }
            let child = nested.first?.listValue == nil
                ? try parseSinglePart(nested) : try parseMultipart(nested)
            children.append(child)
            index += 1
        }
        let subtype = index < items.count ? (items[index].stringValue ?? "") : ""
        let parameters = index + 1 < items.count ? parseParameters(items[index + 1]) : [:]
        let disposition = index + 2 < items.count
            ? parseDisposition(items[index + 2]) : (nil, nil)
        guard !children.isEmpty else {
            throw IMAPFetchParseError.malformedBodyStructure("multipart with no parts")
        }
        return IMAPBodyPart(
            partNumber: nil, mimeType: "multipart/\(subtype.lowercased())",
            parameters: parameters, encoding: nil, size: nil,
            dispositionType: disposition.0, filename: disposition.1,
            children: children)
    }

    /// `("CHARSET" "UTF-8" "NAME" "a.txt")` → `["charset": "UTF-8", "name": "a.txt"]`.
    /// Keys are lowercased (MIME parameter names are case-insensitive); values
    /// are not, since a filename's case is significant.
    private static func parseParameters(_ value: IMAPValue) -> [String: String] {
        guard let items = value.listValue else { return [:] }
        var parameters: [String: String] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].stringValue, let text = items[index + 1].stringValue {
                parameters[key.lowercased()] = text
            }
            index += 2
        }
        return parameters
    }

    /// `("ATTACHMENT" ("FILENAME" "a.txt"))` → `("attachment", "a.txt")`.
    private static func parseDisposition(_ value: IMAPValue) -> (String?, String?) {
        guard let items = value.listValue, let type = items.first?.stringValue else {
            return (nil, nil)
        }
        let parameters = items.count > 1 ? parseParameters(items[1]) : [:]
        return (type.lowercased(), parameters["filename"])
    }

    /// Assigns RFC 3501 §6.4.5 part numbers.
    ///
    /// The rules that matter, and that a naive "number every node" gets wrong:
    /// the top-level `multipart/*` entity has NO part number (only its children
    /// are addressable), while a top-level single part is `"1"`. A numbered
    /// multipart child prefixes its own children (`"2"` → `"2.1"`, `"2.2"`).
    private func numbered(prefix: String?) -> IMAPBodyPart {
        let number: String?
        if isMultipart {
            number = prefix
        } else {
            number = prefix ?? "1"
        }
        let childPrefix = number
        let renumbered = children.enumerated().map { index, child in
            child.numbered(prefix: childPrefix.map { "\($0).\(index + 1)" }
                ?? String(index + 1))
        }
        return IMAPBodyPart(
            partNumber: number, mimeType: mimeType, parameters: parameters,
            encoding: encoding, size: size, dispositionType: dispositionType,
            filename: filename, children: renumbered)
    }
}
