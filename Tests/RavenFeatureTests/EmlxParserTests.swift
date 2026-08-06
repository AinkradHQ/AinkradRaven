import Testing
import Foundation
@testable import RavenFeature

@Suite(".emlx parsing")
struct EmlxParserTests {
    /// Builds a well-formed `.emlx` byte sequence: `<count>\n<rfc822 bytes><plist>`.
    private func emlx(rfc822: String, plist: [String: Any]? = ["flags": ["read": true, "flagged": false]]) -> Data {
        let messageBytes = Data(rfc822.utf8)
        var data = Data("\(messageBytes.count)\n".utf8)
        data.append(messageBytes)
        if let plist {
            data.append(try! PropertyListSerialization.data(fromPropertyList: plist,
                                                             format: .xml, options: 0))
        }
        return data
    }

    @Test("a well-formed .emlx parses headers, body, and flags, reusing RFC 2047 decode")
    func wellFormedParses() {
        let raw = """
        Subject: =?UTF-8?B?SGVsbG8g8J+YgA==?=\r
        From: Alice <alice@example.com>\r
        To: Bob <bob@example.com>\r
        Message-ID: <m1@example.com>\r
        \r
        Hello there.\r
        """
        let data = emlx(rfc822: raw)

        let parsed = EmlxParser.parse(data)
        #expect(parsed != nil)
        #expect(parsed?.message.from?.email == "alice@example.com")
        #expect(parsed?.message.to.first?.email == "bob@example.com")
        #expect(parsed?.message.messageID == "m1@example.com")
        #expect(parsed?.message.plainText.contains("Hello there.") == true)
        #expect(parsed?.isRead == true)
        #expect(parsed?.isFlagged == false)
        // RFC 2047 encoded-word subject decoded via the SAME `RFC2047.decode`
        // used elsewhere — not a second decoder.
        #expect(parsed?.message.subject.contains("Hello") == true)
    }

    @Test("a non-numeric byte-count line is skipped, not a crash")
    func malformedByteCount() {
        var data = Data("not-a-number\n".utf8)
        data.append(Data("Subject: x\r\n\r\nbody".utf8))
        #expect(EmlxParser.parse(data) == nil)
    }

    @Test("a declared byte count longer than the actual content is skipped")
    func truncatedContent() {
        let body = "Subject: x\r\n\r\nshort"
        var data = Data("100000\n".utf8)
        data.append(Data(body.utf8))
        #expect(EmlxParser.parse(data) == nil)
    }

    @Test("a corrupt plist trailer is skipped, not a crash")
    func corruptTrailer() {
        let messageBytes = Data("Subject: x\r\n\r\nbody".utf8)
        var data = Data("\(messageBytes.count)\n".utf8)
        data.append(messageBytes)
        data.append(Data([0xFF, 0x00, 0xDE, 0xAD])) // not a valid plist
        #expect(EmlxParser.parse(data) == nil)
    }

    @Test("an empty file is skipped, not a crash")
    func emptyFile() {
        #expect(EmlxParser.parse(Data()) == nil)
    }

    @Test("a missing plist trailer still parses the message, defaulting flags")
    func missingTrailerStillParses() {
        let data = emlx(rfc822: "Subject: no trailer\r\n\r\nbody", plist: nil)
        let parsed = EmlxParser.parse(data)
        #expect(parsed != nil)
        #expect(parsed?.isRead == false)
        #expect(parsed?.isFlagged == false)
    }
}
