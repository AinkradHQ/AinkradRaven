import Foundation

/// Splits an RFC 5322 address-list header body (`To`, `Cc`, and the Thread
/// surface's own "To" field) into its individual addresses.
///
/// A naïve `split(separator: ",")` is wrong: a display name is allowed to be a
/// quoted string containing commas, so `"Smith, Bea" <bea@x.com>` splits into
/// `"Smith` (no `@`, silently dropped) and `Bea" <bea@x.com>`. That drops or
/// mangles a participant, which is load-bearing now that reply-all builds its
/// recipient list from parsed `To`/`Cc`.
///
/// The split therefore tracks two pieces of context and only treats a comma as
/// a separator when it is outside BOTH:
/// - a double-quoted string (with `\` escaping, per RFC 5322 `quoted-pair`),
/// - an angle-addr (`<...>`), since a mangled or hostile header can hide a
///   comma inside the brackets.
///
/// Anything that is not a parseable address (no `@`) is dropped, exactly as
/// before — this changes only *where* the boundaries fall, never what counts
/// as an address.
public enum AddressListParser {
    /// The raw components of an address list, unparsed and untrimmed-of-nothing
    /// beyond whitespace. Empty components are omitted.
    public static func split(_ list: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false
        var escaped = false

        for character in list {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                current.append(character)
                escaped = true
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<" where !inQuotes:
                inAngles = true
                current.append(character)
            case ">" where !inQuotes:
                inAngles = false
                current.append(character)
            case "," where !inQuotes && !inAngles:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `split` followed by `MailAddress(rfc5322:)`, dropping components that
    /// are not addresses.
    public static func parse(_ list: String) -> [MailAddress] {
        split(list).compactMap { MailAddress(rfc5322: $0) }
    }
}
