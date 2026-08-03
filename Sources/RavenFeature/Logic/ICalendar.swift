import Foundation

/// One attendee or organizer line from a `VEVENT`.
public struct CalendarPerson: Equatable, Sendable {
    public let name: String?
    public let email: String

    public init(name: String?, email: String) {
        self.name = name; self.email = email
    }

    public var displayLabel: String { name ?? email }
}

/// The parsed subset of an iCalendar `VEVENT` that matters for the thread
/// card: enough to show what the invite is about and to build an RSVP, not a
/// general-purpose calendar object model.
public struct CalendarInvite: Equatable, Sendable {
    public enum Method: String, Equatable, Sendable {
        case request = "REQUEST"
        case reply = "REPLY"
        case cancel = "CANCEL"
        case publish = "PUBLISH"
        case unknown
    }

    public let method: Method
    public let uid: String?
    public let summary: String
    public let location: String?
    public let organizer: CalendarPerson?
    public let attendees: [CalendarPerson]
    public let start: Date
    public let end: Date?
    /// True for a `DTSTART` with `VALUE=DATE` (no time component) — rendered
    /// as a day, not a day+time.
    public let isAllDay: Bool
    /// The raw `DTSTART`/`DTEND` value strings and any `TZID`, kept only so a
    /// generated RSVP can echo them back verbatim rather than reformatting a
    /// timezone this parser does not fully resolve.
    public let rawDTStart: String
    public let rawDTStartParams: [String: String]

    public init(method: Method, uid: String?, summary: String, location: String?,
                organizer: CalendarPerson?, attendees: [CalendarPerson],
                start: Date, end: Date?, isAllDay: Bool,
                rawDTStart: String, rawDTStartParams: [String: String]) {
        self.method = method; self.uid = uid; self.summary = summary
        self.location = location; self.organizer = organizer; self.attendees = attendees
        self.start = start; self.end = end; self.isAllDay = isAllDay
        self.rawDTStart = rawDTStart; self.rawDTStartParams = rawDTStartParams
    }
}

/// Parses the iCalendar (RFC 5545) subset carried in a `text/calendar`
/// message part. Two things a naive `split(separator: "\n")` gets wrong and
/// this does not:
///
/// 1. **Line unfolding**: RFC 5545 wraps long lines by inserting a CRLF
///    followed by a single space or tab; a continuation line therefore
///    begins with SP/HTAB and must be rejoined to the previous logical line
///    *before* any `NAME;PARAM=x:VALUE` parsing happens, or a value split
///    mid-line reads as two malformed properties instead of one.
/// 2. **Escaped text**: `TEXT` values (`SUMMARY`, `LOCATION`, `DESCRIPTION`)
///    escape `,`, `;`, `\`, and encode a literal newline as `\n`/`\N`. A
///    plain split on `,`/`;` (needed for `ATTENDEE`'s parameter list) would
///    otherwise cut a comma that was meant to stay inside the text.
public enum ICalendar {
    /// Unfolds CRLF/LF-terminated continuation lines, then splits into
    /// logical property lines. Handles both CRLF and bare-LF line endings —
    /// a real Gmail `text/calendar` part has been observed with either.
    static func unfold(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var logical: [String] = []
        for line in rawLines {
            if let first = line.first, (first == " " || first == "\t"), !logical.isEmpty {
                logical[logical.count - 1] += line.dropFirst()
            } else if !line.isEmpty {
                logical.append(String(line))
            }
        }
        return logical
    }

    /// Un-escapes a `TEXT` value per RFC 5545 §3.3.11: `\,` `\;` `\\` and
    /// `\n`/`\N` (literal newline). Order matters — `\\` must be handled so a
    /// literal backslash immediately before a comma is not itself consumed
    /// by the comma rule.
    static func unescapeText(_ value: String) -> String {
        var out = ""
        var iterator = value.makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else { out.append(char); continue }
            guard let next = iterator.next() else { out.append(char); break }
            switch next {
            case "n", "N": out.append("\n")
            case ",": out.append(",")
            case ";": out.append(";")
            case "\\": out.append("\\")
            default: out.append(next)
            }
        }
        return out
    }

    /// One unfolded logical line, split into `name`, `params`, and `value`.
    private struct Property {
        let name: String
        let params: [String: String]
        let value: String
    }

    /// Splits `NAME;PARAM1=x;PARAM2=y:VALUE` — the colon separating params
    /// from value is the first one NOT inside a quoted param value (a param
    /// value containing `:` or `;`, e.g. a `mailto:` URI as `CN`, is quoted).
    private static func parseProperty(_ line: String) -> Property? {
        var inQuotes = false
        var colonIndex: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" { inQuotes.toggle() }
            else if char == ":" && !inQuotes { colonIndex = index; break }
            index = line.index(after: index)
        }
        guard let colonIndex else { return nil }
        let head = String(line[line.startIndex..<colonIndex])
        let value = String(line[line.index(after: colonIndex)...])
        let headParts = head.split(separator: ";", omittingEmptySubsequences: false)
        guard let name = headParts.first else { return nil }
        var params: [String: String] = [:]
        for part in headParts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex..<eq]).uppercased()
            var paramValue = String(part[part.index(after: eq)...])
            if paramValue.hasPrefix("\"") && paramValue.hasSuffix("\"") && paramValue.count >= 2 {
                paramValue = String(paramValue.dropFirst().dropLast())
            }
            params[key] = paramValue
        }
        return Property(name: String(name).uppercased(), params: params, value: value)
    }

    /// Parses a `DTSTART`/`DTEND`-shaped value into a `Date`, honouring
    /// `VALUE=DATE` (all-day, `YYYYMMDD`) and a `TZID` param when present.
    /// Falls back to UTC for a bare `Z`-suffixed or otherwise timezone-less
    /// value, matching RFC 5545's own floating-time fallback.
    static func parseDate(_ value: String, params: [String: String]) -> (Date, isAllDay: Bool)? {
        if params["VALUE"] == "DATE" || (value.count == 8 && !value.contains("T")) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            guard let date = formatter.date(from: value) else { return nil }
            return (date, true)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        if let tzid = params["TZID"], let zone = TimeZone(identifier: tzid) {
            formatter.timeZone = zone
        } else if value.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else {
            formatter.timeZone = .current
        }
        guard let date = formatter.date(from: value) else { return nil }
        return (date, false)
    }

    /// Parses zero or more `VEVENT`s (only the first is returned — every
    /// invite this app has seen carries exactly one) out of a full
    /// `BEGIN:VCALENDAR…END:VCALENDAR` document, or `nil` if none is found or
    /// the mandatory fields (`DTSTART`, a summary) are missing.
    public static func parseFirstEvent(_ icsText: String) -> CalendarInvite? {
        let lines = unfold(icsText)
        var method: CalendarInvite.Method = .unknown
        for line in lines {
            guard let property = parseProperty(line), property.name == "METHOD" else { continue }
            method = CalendarInvite.Method(rawValue: property.value.uppercased()) ?? .unknown
            break
        }

        guard let eventStart = lines.firstIndex(where: { $0.uppercased() == "BEGIN:VEVENT" }),
              let eventEnd = lines[eventStart...].firstIndex(where: { $0.uppercased() == "END:VEVENT" })
        else { return nil }

        var uid: String?
        var summary = ""
        var location: String?
        var organizer: CalendarPerson?
        var attendees: [CalendarPerson] = []
        var start: Date?
        var end: Date?
        var isAllDay = false
        var rawDTStart = ""
        var rawDTStartParams: [String: String] = [:]

        for line in lines[(eventStart + 1)..<eventEnd] {
            guard let property = parseProperty(line) else { continue }
            switch property.name {
            case "UID":
                uid = property.value
            case "SUMMARY":
                summary = unescapeText(property.value)
            case "LOCATION":
                location = unescapeText(property.value)
            case "ORGANIZER":
                organizer = person(from: property.value, params: property.params)
            case "ATTENDEE":
                if let attendee = person(from: property.value, params: property.params) {
                    attendees.append(attendee)
                }
            case "DTSTART":
                rawDTStart = property.value
                rawDTStartParams = property.params
                if let (date, allDay) = parseDate(property.value, params: property.params) {
                    start = date; isAllDay = allDay
                }
            case "DTEND":
                end = parseDate(property.value, params: property.params)?.0
            default:
                break
            }
        }

        guard let start else { return nil }
        return CalendarInvite(method: method, uid: uid, summary: summary, location: location,
                              organizer: organizer, attendees: attendees, start: start, end: end,
                              isAllDay: isAllDay, rawDTStart: rawDTStart,
                              rawDTStartParams: rawDTStartParams)
    }

    /// `ORGANIZER`/`ATTENDEE` values are `mailto:` URIs with the display name
    /// (if any) carried in the `CN` parameter — `ORGANIZER;CN=Bea Smith:
    /// mailto:bea@example.com`.
    private static func person(from value: String, params: [String: String]) -> CalendarPerson? {
        let email = value.hasPrefix("mailto:") || value.hasPrefix("MAILTO:")
            ? String(value.dropFirst("mailto:".count))
            : value
        guard !email.isEmpty else { return nil }
        return CalendarPerson(name: params["CN"], email: email)
    }
}
