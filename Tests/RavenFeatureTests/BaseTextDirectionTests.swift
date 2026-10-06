import Foundation
import Testing

@testable import RavenFeature

@Suite("BaseTextDirection")
struct BaseTextDirectionTests {
    @Test("an Arabic body is right-to-left")
    func arabic() {
        #expect(BaseTextDirection.detect("السلام عليكم، كيف حالك؟") == .rightToLeft)
    }

    @Test("an English body is left-to-right")
    func english() {
        #expect(BaseTextDirection.detect("Hello, how are you?") == .leftToRight)
    }

    @Test("empty and neutral-only text defaults to left-to-right")
    func neutral() {
        #expect(BaseTextDirection.detect("") == .leftToRight)
        #expect(BaseTextDirection.detect("123 -- 456 !!!") == .leftToRight)
    }

    @Test("an embedded Latin URL does not flip an Arabic message")
    func embeddedLatinRun() {
        #expect(
            BaseTextDirection.detect("تفضل الرابط هنا فضلا وشكرا جزيلا لك يا صديقي https://x.co")
                == .rightToLeft)
    }

    @Test("an Arabic reply to a long English thread is still right-to-left")
    func arabicReplyToEnglishThread() {
        // The rule that matters most for this user: the quoted original and its
        // attribution must not decide the direction of what they are writing.
        let reply = """
            شكرا جزيلا

            On Jan 1, 2020 at 9:00 AM, Beatrice Smith wrote:
            > Thank you very much for the update, I have reviewed the whole document
            > and everything looks correct to me. Let us proceed as planned tomorrow.
            """
        #expect(BaseTextDirection.detect(reply) == .rightToLeft)
    }

    @Test("only the authored portion is weighed, but a quote-only draft still resolves")
    func quoteOnlyFallback() {
        let quoteOnly = "\n\nOn Jan 1, 2020 at 9:00 AM, x wrote:\n> السلام عليكم ورحمة الله"
        // Nothing authored: falls back to the whole text rather than returning
        // a direction read from an empty string.
        #expect(BaseTextDirection.detect(quoteOnly) == .rightToLeft)
    }

    @Test("digits and punctuation are neutral, letters are not")
    func classification() {
        #expect(BaseTextDirection.isStrongRTL("م"))
        #expect(BaseTextDirection.isStrongRTL("ש"))
        #expect(!BaseTextDirection.isStrongRTL("a"))
        #expect(BaseTextDirection.isStrongLTR("a"))
        #expect(!BaseTextDirection.isStrongLTR("م"))
        #expect(!BaseTextDirection.isStrongLTR("5"))
        #expect(!BaseTextDirection.isStrongLTR("!"))
    }

    @Test("the HTML dir attribute value matches the direction")
    func htmlDir() {
        #expect(BaseTextDirection.rightToLeft.htmlDir == "rtl")
        #expect(BaseTextDirection.leftToRight.htmlDir == "ltr")
    }
}
