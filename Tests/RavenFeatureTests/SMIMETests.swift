import Testing
import Foundation
import Security
@testable import RavenFeature

/// Exercises the real `CMSEncoder`/`CMSDecoder` code path against a
/// throwaway, self-signed test identity created fresh per test in a
/// temporary keychain (`TestSMIMEIdentity`) — never the user's real login
/// keychain, and never a mocked CMS layer.
///
/// What this CANNOT prove (see the task's constraints): interop with a real
/// Mail.app/Gmail-issued, CA-trusted S/MIME certificate. Only "well-formed
/// and self-verifies with the same CMS APIs a real client uses" is claimed.
@Suite(.serialized)
struct SMIMETests {
    private func withIdentity(_ body: (SecIdentity) throws -> Void) throws {
        let handle = try TestSMIMEIdentity.make()
        defer { TestSMIMEIdentity.destroy(handle) }
        try body(handle.identity)
    }

    @Test("a valid S/MIME signature verifies as .signedValid")
    func validSignatureVerifiesAsSignedValid() throws {
        try withIdentity { identity in
            let content = Data("Content-Type: text/plain; charset=UTF-8\r\n\r\nHello, world.\r\n".utf8)
            let signature = try #require(SMIME.sign(content: content, identity: identity))
            #expect(SMIME.verify(signedContent: content, signature: signature) == .signedValid)
        }
    }

    @Test("flipping one byte in the signed content verifies as .signedInvalid")
    func tamperedContentVerifiesAsSignedInvalid() throws {
        try withIdentity { identity in
            let content = Data("Content-Type: text/plain; charset=UTF-8\r\n\r\nHello, world.\r\n".utf8)
            let signature = try #require(SMIME.sign(content: content, identity: identity))
            var tampered = content
            tampered[tampered.count - 3] ^= 0xFF
            #expect(SMIME.verify(signedContent: tampered, signature: signature) == .signedInvalid)
        }
    }

    @Test("flipping one byte in the signature blob verifies as .signedInvalid")
    func tamperedSignatureVerifiesAsSignedInvalid() throws {
        try withIdentity { identity in
            let content = Data("Content-Type: text/plain; charset=UTF-8\r\n\r\nHello, world.\r\n".utf8)
            var signature = try #require(SMIME.sign(content: content, identity: identity))
            // The CMS `SignedData`'s embedded certificate sits ahead of the
            // `SignerInfo`'s actual signature value in the DER encoding, and
            // — since `verify` deliberately skips trust-chain evaluation —
            // flipping a byte inside that certificate does not necessarily
            // invalidate the signature check. The last several bytes are the
            // tail of the SignerInfo's signature octet string itself, so
            // corrupting them is guaranteed to break the cryptographic check.
            for i in (signature.count - 8)..<signature.count {
                signature[i] ^= 0xFF
            }
            #expect(SMIME.verify(signedContent: content, signature: signature) == .signedInvalid)
        }
    }

    @Test("a MessageBody with no signature information defaults to .unsigned")
    func defaultMessageBodyIsUnsigned() {
        let body = MessageBody(messageID: "m1", plainText: "hi", html: nil)
        #expect(body.signatureStatus == .unsigned)
    }

    @Test("decoding a pre-S/MIME persisted MessageBody document (no signatureStatus key) defaults to .unsigned")
    func decodingOlderDocumentDefaultsToUnsigned() throws {
        let json = """
        {"messageID":"m1","plainText":"hi","html":null}
        """
        let decoded = try JSONDecoder().decode(MessageBody.self, from: Data(json.utf8))
        #expect(decoded.signatureStatus == .unsigned)
    }

    @Test("SMIME.canonicalPart's output has no bare LF anywhere — CRLF-only, headers and body")
    func canonicalPartIsCRLFOnly() {
        let canonical = SMIME.canonicalPart(
            headerLines: ["Content-Type: text/plain; charset=UTF-8"],
            body: "line one\nline two\nline three")
        assertNoBareLF(canonical)
        #expect(canonical.contains(Data("\r\n\r\n".utf8)))
    }

    /// Asserts there is no `\n` anywhere in `data` that is not immediately
    /// preceded by `\r` — the literal CRLF-canonicalization invariant the
    /// task requires be checked at the byte level, not just "looks CRLF-ish".
    private func assertNoBareLF(_ data: Data) {
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A {
                #expect(previous == 0x0D, "found a bare LF not preceded by CR")
            }
            previous = byte
        }
    }

    // MARK: GmailProvider.rfc822 signing

    private func message(accountID: String?) -> OutgoingMessage {
        OutgoingMessage(to: [MailAddress(email: "bob@example.com", name: nil)],
                        subject: "Signed?", bodyText: "Hello from a test.",
                        accountID: accountID)
    }

    @Test("signing is skipped cleanly (message sent unsigned, no thrown error) when no identity is found")
    func noIdentityMeansUnsignedSend() {
        let raw = GmailProvider.rfc822(message(accountID: "alice@example.com")) { _ in nil }
        let decoded = decodeRaw(raw)
        #expect(decoded.contains("multipart/signed") == false)
        #expect(decoded.contains("multipart/alternative"))
    }

    @Test("with no accountID at all, signing is never attempted and the message is unsigned")
    func noAccountIDMeansUnsignedSend() {
        var lookupCalled = false
        let raw = GmailProvider.rfc822(message(accountID: nil)) { _ in
            lookupCalled = true
            return nil
        }
        #expect(lookupCalled == false)
        #expect(decodeRaw(raw).contains("multipart/signed") == false)
    }

    @Test("with a signing identity available, the message becomes multipart/signed with a detached pkcs7-signature part, and it verifies")
    func signedSendProducesValidMultipartSigned() throws {
        try withIdentity { identity in
            let raw = GmailProvider.rfc822(message(accountID: "alice@example.com")) { _ in identity }
            let decoded = decodeRaw(raw)
            #expect(decoded.contains("multipart/signed; protocol=\"application/pkcs7-signature\""))
            #expect(decoded.contains("application/pkcs7-signature"))

            let (contentTypeLine, body) = try splitOutSignedEnvelope(decoded)
            let parsed = try #require(SMIME.parseMultipartSigned(contentTypeLine: contentTypeLine, body: body))
            assertNoBareLF(parsed.signedContent)
            #expect(SMIME.verify(signedContent: parsed.signedContent, signature: parsed.signature) == .signedValid)
        }
    }

    @Test("tampering the signed body after signing makes the same message verify as .signedInvalid")
    func tamperedSignedSendVerifiesAsInvalid() throws {
        try withIdentity { identity in
            let raw = GmailProvider.rfc822(message(accountID: "alice@example.com")) { _ in identity }
            let decoded = decodeRaw(raw)
            let (contentTypeLine, body) = try splitOutSignedEnvelope(decoded)
            var parsed = try #require(SMIME.parseMultipartSigned(contentTypeLine: contentTypeLine, body: body))
            parsed.signedContent[parsed.signedContent.count - 5] ^= 0xFF
            #expect(SMIME.verify(signedContent: parsed.signedContent, signature: parsed.signature) == .signedInvalid)
        }
    }

    // MARK: helpers

    private func decodeRaw(_ base64URL: String) -> String {
        var normalized = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        guard let data = Data(base64Encoded: normalized) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The raw RFC822 text's headers section ends at the top-level blank
    /// line; from there, the top-level `Content-Type:` header line and
    /// everything after the blank line that follows it is exactly what
    /// `SMIME.parseMultipartSigned` expects.
    private func splitOutSignedEnvelope(_ raw: String) throws -> (contentTypeLine: String, body: String) {
        guard let headerBodySplit = raw.range(of: "\r\n\r\n") else {
            throw TestError.malformed
        }
        let headerBlock = String(raw[..<headerBodySplit.lowerBound])
        let body = String(raw[headerBodySplit.upperBound...])
        guard let contentTypeLine = headerBlock
            .components(separatedBy: "\r\n")
            .first(where: { $0.hasPrefix("Content-Type:") }) else {
            throw TestError.malformed
        }
        return (contentTypeLine, body)
    }

    private enum TestError: Swift.Error { case malformed }
}
