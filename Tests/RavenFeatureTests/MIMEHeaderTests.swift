import Testing
import Foundation
@testable import RavenFeature

/// The header-emission chokepoint. Header injection was possible because
/// `RFC2047.encode` returns pure-ASCII input unchanged, so an ASCII value with
/// a CRLF in it was interpolated verbatim and ended the header line.
@Suite("MIME header sanitizing")
struct MIMEHeaderTests {

    @Test("CRLF, bare CR and bare LF are all stripped from a header value")
    func lineBreaksAreStripped() {
        for injected in ["a\r\nb", "a\rb", "a\nb", "a\n\rb"] {
            let line = MIMEHeader.line("Subject", injected)
            #expect(line.contains("\r") == false, "CR survived in \(line.debugDescription)")
            #expect(line.contains("\n") == false, "LF survived in \(line.debugDescription)")
            // The words are kept, separated rather than run together.
            #expect(line.contains("a"))
            #expect(line.contains("b"))
        }
    }

    @Test("other C0 controls and DEL are stripped, but tab survives as legal folding whitespace")
    func otherControlsStripped() {
        #expect(MIMEHeader.line("Subject", "a\u{0}b\u{7F}c").contains("\u{0}") == false)
        #expect(MIMEHeader.line("Subject", "a\tb").contains("\t"))
    }

    @Test("a header name cannot smuggle a line break either")
    func headerNameIsSanitized() {
        let line = MIMEHeader.literalLine("X-Thing\r\nBcc", "value")
        #expect(line.contains("\r\n") == false)
    }

    @Test("an address's email and display name are each sanitized before the list is joined")
    func addressFieldsSanitized() {
        let line = MIMEHeader.addressLine("To", [
            MailAddress(email: "a@example.com\r\nBcc: attacker@evil.com", name: nil),
            MailAddress(email: "b@example.com", name: "Bea\r\nBcc: attacker@evil.com"),
        ])
        #expect(line.contains("\r") == false)
        #expect(line.contains("\n") == false)
    }

    @Test("an ASCII display name containing a comma is quoted so it cannot split the address list")
    func commaInDisplayNameIsQuoted() {
        let line = MIMEHeader.addressLine("To", [
            MailAddress(email: "bea@example.com", name: "Smith, Bea"),
            MailAddress(email: "c@example.com", name: nil),
        ])
        #expect(line.contains("\"Smith, Bea\" <bea@example.com>"))
        // Round-trips back to two addresses, not three.
        let value = String(line.dropFirst("To: ".count))
        let parsed = AddressListParser.parse(value)
        #expect(parsed.count == 2)
        #expect(parsed.first?.name == "Smith, Bea")
    }

    @Test("a non-ASCII value is still RFC 2047 encoded after sanitizing, and its folds are legal")
    func nonASCIIStillEncodes() {
        let line = MIMEHeader.line("Subject", "مرحبا\r\nBcc: attacker@evil.com")
        #expect(line.contains("=?UTF-8?B?"))
        // The only line breaks left are RFC 2047 folds: CRLF followed by
        // whitespace. A fold at the start of a line, or a lone LF, is not.
        for (index, character) in Array(line).enumerated() where character == "\n" {
            #expect(index > 0 && Array(line)[index - 1] == "\r")
            #expect(index + 1 < line.count && Array(line)[index + 1] == " ")
        }
        #expect(RFC2047.decode(line).contains("Bcc") )
        // …decoded back it is TEXT inside the subject, not a header.
        #expect(RFC2047.decode(line).contains("\r\nBcc") == false)
    }

    // MARK: CRLF normalisation and transfer encoding

    @Test("bare LF is promoted to CRLF without ever producing CR CR LF")
    func normalizesToCRLF() {
        #expect(MIMEHeader.normalizeCRLF("a\nb") == "a\r\nb")
        #expect(MIMEHeader.normalizeCRLF("a\r\nb") == "a\r\nb")
        #expect(MIMEHeader.normalizeCRLF("a\rb") == "a\r\nb")
        #expect(MIMEHeader.normalizeCRLF("a\r\nb\nc\rd") == "a\r\nb\r\nc\r\nd")
        #expect(MIMEHeader.normalizeCRLF("a\r\nb").contains("\r\r") == false)
    }

    @Test("base64 part content is CRLF-normalized, wrapped to 76 columns, and decodes back exactly")
    func base64BodyIsWrappedAndExact() {
        let text = "Line one\nLine two\n" + String(repeating: "long ", count: 400)
        let encoded = MIMEHeader.base64Body(text)
        for line in encoded.components(separatedBy: "\r\n") {
            #expect(line.count <= 76)
        }
        let joined = encoded.replacingOccurrences(of: "\r\n", with: "")
        let data = Data(base64Encoded: joined)
        #expect(data != nil)
        #expect(String(data: data ?? Data(), encoding: .utf8)
            == MIMEHeader.normalizeCRLF(text))
    }
}

/// Address-list splitting. A naïve comma split dropped a participant whose
/// display name was a quoted string containing a comma — which now feeds
/// reply-all.
@Suite("Address list parsing")
struct AddressListParserTests {

    @Test("a quoted display name containing a comma stays one address")
    func quotedCommaIsNotASeparator() {
        let parsed = AddressListParser.parse("\"Smith, Bea\" <bea@x.com>, cal@y.com")
        #expect(parsed.count == 2)
        #expect(parsed[0].email == "bea@x.com")
        #expect(parsed[0].name == "Smith, Bea")
        #expect(parsed[1].email == "cal@y.com")
    }

    @Test("the naive split's failure mode is gone: no participant is dropped")
    func participantIsNotDropped() {
        let header = "\"Smith, Bea\" <bea@x.com>, \"Jones, Cal\" <cal@y.com>"
        #expect("\(header)".split(separator: ",").count == 4)   // what used to happen
        #expect(AddressListParser.parse(header).count == 2)     // what happens now
    }

    @Test("ordinary lists, extra whitespace and bare addresses still parse as before")
    func ordinaryListsUnaffected() {
        #expect(AddressListParser.parse("a@x.com, b@y.com").map(\.email) == ["a@x.com", "b@y.com"])
        #expect(AddressListParser.parse("  a@x.com ,b@y.com  ").map(\.email)
            == ["a@x.com", "b@y.com"])
        #expect(AddressListParser.parse("Bea <bea@x.com>").first?.name == "Bea")
        #expect(AddressListParser.parse("").isEmpty)
        #expect(AddressListParser.parse("not an address").isEmpty)
    }

    @Test("a comma hidden inside angle brackets does not split the list")
    func commaInsideAnglesIsNotASeparator() {
        let parsed = AddressListParser.parse("Bea <bea@x.com, evil@y.com>")
        #expect(parsed.count == 1)
    }

    @Test("an escaped quote inside a quoted name does not unbalance the parser")
    func escapedQuoteHandled() {
        let parsed = AddressListParser.parse("\"Bea \\\" Smith, Jr\" <bea@x.com>, cal@y.com")
        #expect(parsed.count == 2)
        #expect(parsed[1].email == "cal@y.com")
    }
}
