import Foundation
import Security

/// Builds a throwaway, self-signed S/MIME test identity in a temporary,
/// on-disk keychain created fresh for each call and deleted by the caller
/// via `TestSMIMEIdentity.destroy` — this NEVER touches the user's real
/// login keychain (production code path never calls anything in this file).
///
/// Security.framework has no public "create an identity from a fresh
/// keypair" call: a `SecIdentity` is a keychain's own pairing of a
/// certificate and its matching private key. So this: generates an RSA
/// keypair with the private key stored in the temporary keychain, hand-rolls
/// a minimal self-signed X.509v1 DER certificate around the matching public
/// key (Security.framework itself is only used to sign the certificate's
/// TBS bytes and to import the resulting DER — no ASN.1 library, no new
/// dependency), stores the certificate in the same keychain, then looks the
/// pairing up as a `SecIdentity`.
enum TestSMIMEIdentity {
    struct Handle {
        let identity: SecIdentity
        let keychain: SecKeychain
        let path: String
    }

    enum Error: Swift.Error { case step(String, OSStatus) }

    static func make() throws -> Handle {
        let path = NSTemporaryDirectory() + "raven-smime-test-\(UUID().uuidString).keychain"
        var keychainRef: SecKeychain?
        let password = UUID().uuidString
        var status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychainRef)
        guard status == errSecSuccess, let keychain = keychainRef else {
            throw Error.step("SecKeychainCreate", status)
        }

        var publicKeyRef: SecKey?
        var privateKeyRef: SecKey?
        let keyAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        status = SecKeyGeneratePair(keyAttrs as CFDictionary, &publicKeyRef, &privateKeyRef)
        guard status == errSecSuccess, let publicKey = publicKeyRef, let privateKey = privateKeyRef else {
            throw Error.step("SecKeyGeneratePair", status)
        }
        // `SecKeyGeneratePair` with no `kSecUseKeychain` lands the pair in the
        // default keychain search list's writable keychain, not our fresh
        // temporary one — move the private key into it explicitly.
        let addKeyQuery: [CFString: Any] = [
            kSecValueRef: privateKey,
            kSecUseKeychain: keychain,
        ]
        var addResult: CFTypeRef?
        status = SecItemAdd(addKeyQuery as CFDictionary, &addResult)
        // Some SDKs land the key in the intended keychain as a side effect of
        // `kSecUseKeychain` during generation and reject a second `SecItemAdd`
        // of the same item (`errSecDuplicateItem`) — either outcome means the
        // key already lives where it needs to, so both are accepted.
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Error.step("SecItemAdd(privateKey)", status)
        }

        let publicKeyDER = try copyExternalRepresentation(publicKey)
        let certificateDER = try selfSignedCertificate(publicKeyDER: publicKeyDER, privateKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw Error.step("SecCertificateCreateWithData", errSecParam)
        }
        let addCertQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecUseKeychain: keychain,
        ]
        var certAddResult: CFTypeRef?
        status = SecItemAdd(addCertQuery as CFDictionary, &certAddResult)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Error.step("SecItemAdd(certificate)", status)
        }

        let identityQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: true,
            kSecMatchSearchList: [keychain],
        ]
        var identityResult: CFTypeRef?
        status = SecItemCopyMatching(identityQuery as CFDictionary, &identityResult)
        guard status == errSecSuccess, let identityRef = identityResult else {
            throw Error.step("SecItemCopyMatching(identity)", status)
        }
        return Handle(identity: (identityRef as! SecIdentity), keychain: keychain, path: path)
    }

    static func destroy(_ handle: Handle) {
        SecKeychainDelete(handle.keychain)
        try? FileManager.default.removeItem(atPath: handle.path)
    }

    private static func copyExternalRepresentation(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) else {
            throw Error.step("SecKeyCopyExternalRepresentation", errSecParam)
        }
        return data as Data
    }

    // MARK: Minimal ASN.1 DER

    private static func der(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var n = count
            while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
            out.append(UInt8(0x80 | bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }
    private static func sequence(_ content: Data) -> Data { der(tag: 0x30, content) }
    private static func integer(_ value: UInt8) -> Data { der(tag: 0x02, Data([value])) }
    private static func bitString(_ content: Data) -> Data { der(tag: 0x03, Data([0x00]) + content) }
    private static func oid(_ bytes: [UInt8]) -> Data { der(tag: 0x06, Data(bytes)) }
    private static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return der(tag: 0x17, Data(formatter.string(from: date).utf8))
    }
    private static func rdnCommonName(_ value: String) -> Data {
        // RDNSequence { RelativeDistinguishedName { AttributeTypeAndValue {
        // OID commonName, PrintableString value } } }
        let cnOID = oid([0x55, 0x04, 0x03])  // 2.5.4.3
        let printable = der(tag: 0x13, Data(value.utf8))
        let attr = sequence(cnOID + printable)
        let rdn = der(tag: 0x31, attr)  // SET
        return sequence(rdn)
    }

    private static let sha256WithRSAEncryption: [UInt8] =
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]  // 1.2.840.113549.1.1.11
    private static let rsaEncryption: [UInt8] =
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]  // 1.2.840.113549.1.1.1

    private static func algorithmIdentifier(_ oidBytes: [UInt8]) -> Data {
        sequence(oid(oidBytes) + der(tag: 0x05, Data()))  // + NULL params
    }

    /// Hand-rolls a minimal self-signed X.509v1 certificate, using
    /// `publicKeyDER` (the PKCS#1 `RSAPublicKey` `SecKeyCopyExternalRepresentation`
    /// returns for an RSA public key) as the subject's key and `privateKey`
    /// to sign it — real Security.framework code, not a stub, is what
    /// produces the signature `SMIME.sign`/`CMSEncoder` will later re-verify
    /// the whole certificate chain against (to the extent this environment
    /// can — see `SMIME.verify`'s doc comment on trust-chain scope).
    private static func selfSignedCertificate(publicKeyDER: Data, privateKey: SecKey) throws -> Data {
        let serialNumber = integer(1)
        let signatureAlg = algorithmIdentifier(sha256WithRSAEncryption)
        let issuer = rdnCommonName("Raven S/MIME Test")
        let subject = issuer
        let notBefore = utcTime(Date().addingTimeInterval(-3600))
        let notAfter = utcTime(Date().addingTimeInterval(3600 * 24))
        let validity = sequence(notBefore + notAfter)
        let subjectPublicKeyInfo = sequence(algorithmIdentifier(rsaEncryption) + bitString(publicKeyDER))

        let tbsCertificate = sequence(
            serialNumber + signatureAlg + issuer + validity + subject + subjectPublicKeyInfo)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbsCertificate as CFData, &error
        ) else {
            throw Error.step("SecKeyCreateSignature", errSecParam)
        }

        let certificate = sequence(tbsCertificate + signatureAlg + bitString(signature as Data))
        return certificate
    }
}
