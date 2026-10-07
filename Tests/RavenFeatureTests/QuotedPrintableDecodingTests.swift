import Foundation
import Testing

@testable import RavenFeature

/// Quoted-printable bodies as servers actually send them: CRLF line endings.
/// Swift reads `"\r\n"` as ONE `Character`, so a decoder that walks a `String`
/// never sees a soft line break `=\r\n` and leaves `paymen=` / `ts` in the
/// rendered mail. These cases pin the byte-level behaviour.
struct QuotedPrintableDecodingTests {
    private func decode(_ text: String) -> String {
        let out = RFC822Message.decodeTransferEncoding(Data(text.utf8), encoding: "quoted-printable")
        return String(decoding: out, as: UTF8.self)
    }

    @Test func crlfSoftLineBreakJoinsTheLine() {
        #expect(decode("scheduled paymen=\r\nts, will\r\ncontinue") == "scheduled payments, will\r\ncontinue")
    }

    @Test func lfSoftLineBreakJoinsTheLine() {
        #expect(decode("paymen=\nts") == "payments")
    }

    @Test func hexEscapesDecodeInEitherCase() {
        #expect(decode("caf=C3=A9 and caf=c3=a9") == "café and café")
    }

    @Test func eightBitBytesPassThroughInsteadOfAbandoningTheBody() {
        let raw = Data([0x41, 0xE9, 0x3D, 0x0D, 0x0A, 0x42])  // "A", é (latin-1), soft break, "B"
        let out = RFC822Message.decodeTransferEncoding(raw, encoding: "quoted-printable")
        #expect(out == Data([0x41, 0xE9, 0x42]))
    }

    @Test func aLoneEqualsSignIsKeptLiterally() {
        #expect(decode("a = b and 100%=") == "a = b and 100%=")
    }
}

/// Bodies cached before the byte-level decoder carry `decoderVersion == nil`;
/// opening such a message fetches it again, and an offline fetch still shows
/// the old copy rather than nothing.
@MainActor struct StaleBodyRefetchTests: MultiAccountFixtures {
    private func runtime(_ provider: FakeMailProvider) throws -> (RavenRuntime, MailMessage) {
        let runtime = RavenRuntime(host: FakeHostServices())
        let t = thread("t1", account: "a1", subject: "s", date: Date())
        try runtime.store.upsertThread(t)
        runtime.providers.attach(provider, accountID: "a1")
        try runtime.store.saveBody(
            MessageBody(messageID: "m-t1", plainText: "paymen=\r\nts", html: nil, decoderVersion: nil),
            accountID: "a1")
        return (runtime, t.messages[0])
    }

    @Test func aBodyFromTheOldDecoderIsFetchedAgain() async throws {
        let provider = FakeMailProvider(accountID: "a1")
        provider.bodies["m-t1"] = MessageBody(messageID: "m-t1", plainText: "payments", html: nil)
        let (runtime, message) = try runtime(provider)
        let body = await runtime.loadBody(for: message)
        #expect(body?.plainText == "payments")
        #expect(runtime.store.body(messageID: "m-t1")?.decoderVersion == MessageBody.currentDecoderVersion)
    }

    @Test func aFailedRefetchStillShowsTheCachedBody() async throws {
        let provider = FakeMailProvider(accountID: "a1")
        provider.failures["fetchBody"] = [MailError.providerFailed(status: 503, message: "offline")]
        let (runtime, message) = try runtime(provider)
        let body = await runtime.loadBody(for: message)
        #expect(body?.plainText == "paymen=\r\nts")
    }
}
