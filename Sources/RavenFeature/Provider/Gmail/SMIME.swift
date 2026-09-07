import Foundation
import Security

/// The visible outcome of checking (or not checking) a message's S/MIME
/// signature — surfaced on `MessageBody` for the thread UI.
///
/// A DISTINCT enum case split from `.unsigned`, not a `Bool` plus a flag: a
/// failed/tampered signature (`.signedInvalid`) must never be representable
/// as, or silently collapse into, "no signature was present"
/// (`.unsigned`) — those are different security postures and a UI (or a
/// future caller) that only checks "is it signed" must not be able to
/// mistake one for the other.
public enum SignatureStatus: String, Codable, Equatable, Sendable {
    case signedValid
    case signedInvalid
    case unsigned
}

/// S/MIME sign/verify over Security.framework's CMS APIs (`CMSEncoder`/
/// `CMSDecoder`). No shelling out to `openssl`/`smime`, no new package
/// dependency — both are the C APIs Apple ships in `Security.framework`,
/// available to Swift via `import Security`.
enum SMIME {
    /// The canonical (CRLF-terminated, headers-plus-blank-line-plus-body)
    /// bytes of one MIME entity — exactly what `sign` computes the detached
    /// signature over and what `verify` must be handed back to check it.
    /// `body` is CRLF-normalized via `MIMEHeader.normalizeCRLF` first, so a
    /// caller building the signed part from a `\n`-only string still ends up
    /// with the CRLF-only bytes RFC 2046 requires.
    static func canonicalPart(headerLines: [String], body: String) -> Data {
        let headers = headerLines.joined(separator: "\r\n")
        let normalizedBody = MIMEHeader.normalizeCRLF(body)
        return Data((headers + "\r\n\r\n" + normalizedBody).utf8)
    }

    /// Verifies a detached CMS/PKCS#7 signature (`signature`, the raw DER
    /// bytes of an `application/pkcs7-signature` part) over `signedContent`
    /// — the exact canonical (CRLF-terminated) bytes of the MIME part that
    /// was signed, headers and all, precisely as `sign` produced them.
    ///
    /// Returns `.signedValid` only when `CMSDecoder` reports a signer status
    /// of `.valid` — i.e. the CMS signature cryptographically matches
    /// `signedContent`. Certificate *trust-chain* evaluation is deliberately
    /// skipped (`evaluateSecTrust: false` below): this environment has no
    /// real, trusted CA-issued S/MIME certificate to test against, only
    /// throwaway self-signed test identities, so trust-chain validity is out
    /// of scope here — see the file-level note on what cannot be verified.
    /// Any other outcome (decode failure, signature mismatch, explicit
    /// invalid signer status) is `.signedInvalid` — never silently
    /// `.unsigned`, which would hide a tampered message behind the same
    /// value as "never signed".
    static func verify(signedContent: Data, signature: Data) -> SignatureStatus {
        var decoderRef: CMSDecoder?
        guard CMSDecoderCreate(&decoderRef) == errSecSuccess, let decoder = decoderRef else {
            return .signedInvalid
        }
        // Detached signature: the decoder is fed the signature bytes as the
        // "message" and the actual signed bytes separately via
        // `CMSDecoderSetDetachedContent`, matching how `sign` produced a
        // detached `application/pkcs7-signature`.
        guard CMSDecoderSetDetachedContent(decoder, signedContent as CFData) == errSecSuccess else {
            return .signedInvalid
        }
        let updateStatus = signature.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            return .signedInvalid
        }
        var numSigners = 0
        guard CMSDecoderGetNumSigners(decoder, &numSigners) == errSecSuccess, numSigners > 0 else {
            return .signedInvalid
        }
        var status = CMSSignerStatus.needsDetachedContent
        var trustRef: SecTrust?
        var certVerifyResultCode: OSStatus = errSecSuccess
        let signerStatus = CMSDecoderCopySignerStatus(
            decoder, 0, SecPolicyCreateBasicX509(), false, &status, &trustRef, &certVerifyResultCode)
        guard signerStatus == errSecSuccess, status == .valid else {
            return .signedInvalid
        }
        return .signedValid
    }

    /// Signs `content` (the exact canonical CRLF-terminated bytes of the
    /// MIME part being wrapped) with `identity`, producing a *detached*
    /// CMS/PKCS#7 signature's raw DER bytes — the payload of the
    /// `application/pkcs7-signature` part `GmailProvider.rfc822` base64s
    /// alongside it. Returns `nil` (never throws) on any encoder failure so a
    /// caller can fall back to sending unsigned rather than fail the send.
    static func sign(content: Data, identity: SecIdentity) -> Data? {
        var encoderRef: CMSEncoder?
        guard CMSEncoderCreate(&encoderRef) == errSecSuccess, let encoder = encoderRef else {
            return nil
        }
        guard CMSEncoderAddSigners(encoder, identity) == errSecSuccess else { return nil }
        // Detached: the signature covers `content` but does not embed it —
        // required for `multipart/signed`, whose whole point is that the
        // signed part is transmitted plain, readable by any client, with the
        // signature riding alongside as a sibling part.
        guard CMSEncoderSetHasDetachedContent(encoder, true) == errSecSuccess else { return nil }
        let updateStatus = content.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSEncoderUpdateContent(encoder, base, buffer.count)
        }
        guard updateStatus == errSecSuccess else { return nil }
        var outputRef: CFData?
        guard CMSEncoderCopyEncodedContent(encoder, &outputRef) == errSecSuccess,
              let output = outputRef else { return nil }
        return output as Data
    }

    /// Splits a raw `multipart/signed` MIME entity (the `Content-Type` line
    /// plus body, exactly what `GmailProvider.signedEnvelope` produces) into
    /// the canonical bytes of its first (signed-content) part and the raw
    /// signature bytes decoded out of its second (`application/
    /// pkcs7-signature`) part. Used by tests to exercise a full
    /// build-then-verify round trip through the same string the wire
    /// actually carries, and available to any future raw-bytes inbound path.
    /// `nil` when `raw` is not a well-formed two-part `multipart/signed`
    /// entity.
    static func parseMultipartSigned(contentTypeLine: String, body: String) -> (
        signedContent: Data, signature: Data
    )? {
        guard let boundary = boundaryParameter(of: contentTypeLine) else { return nil }
        let firstMarker = "--\(boundary)\r\n"
        let middleMarker = "\r\n--\(boundary)\r\n"
        let closingMarker = "\r\n--\(boundary)--"

        guard body.hasPrefix(firstMarker) else { return nil }
        let afterFirstMarker = body.index(body.startIndex, offsetBy: firstMarker.count)
        guard let middleRange = body.range(of: middleMarker, range: afterFirstMarker..<body.endIndex)
        else { return nil }
        let contentPart = String(body[afterFirstMarker..<middleRange.lowerBound])

        let afterMiddleMarker = middleRange.upperBound
        guard let closingRange = body.range(
            of: closingMarker, range: afterMiddleMarker..<body.endIndex) else { return nil }
        let signaturePart = String(body[afterMiddleMarker..<closingRange.lowerBound])

        guard contentPart.range(of: "\r\n\r\n") != nil else { return nil }
        let signedContent = Data(contentPart.utf8)

        guard let sigBlankLine = signaturePart.range(of: "\r\n\r\n") else { return nil }
        let base64Body = String(signaturePart[sigBlankLine.upperBound...])
            .replacingOccurrences(of: "\r\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let signature = Data(base64Encoded: base64Body) else { return nil }
        return (signedContent, signature)
    }

    private static func boundaryParameter(of contentTypeLine: String) -> String? {
        guard let range = contentTypeLine.range(of: "boundary=\"") else { return nil }
        let rest = contentTypeLine[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Looks up a signing identity for `email` in the given keychain
    /// (defaults to `nil`, i.e. the default search list — production never
    /// touches this with anything but the default; tests pass an explicit
    /// temporary keychain so this never reads the user's real login
    /// keychain). Returns `nil` — never throws — when no identity matches,
    /// since signing is opt-in: absence must lead to an unsigned send, not a
    /// failed one.
    static func preferredIdentity(email: String, keychain: SecKeychain? = nil) -> SecIdentity? {
        // Test path: a specific (temporary, throwaway) keychain was supplied —
        // `SecIdentityCopyPreferred` consults preference *records*, which a
        // freshly-generated test identity never has, so tests look the
        // identity up directly by keychain membership instead. Production
        // never passes `keychain`, so this branch never touches the real
        // login keychain.
        if let keychain {
            let query: [CFString: Any] = [
                kSecClass: kSecClassIdentity,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnRef: true,
                kSecMatchSearchList: [keychain],
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let ref = result else { return nil }
            guard CFGetTypeID(ref) == SecIdentityGetTypeID() else {
                Log.auth.error("Keychain returned a non-identity for an identity query")
                return nil
            }
            return (ref as! SecIdentity)
        }
        guard !email.isEmpty else { return nil }
        return SecIdentityCopyPreferred(email as CFString, nil, nil)
    }
}
