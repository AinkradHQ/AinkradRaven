import Testing
import Foundation
@testable import RavenFeature

@Suite("RecipientChip and ComposeValidation")
struct RecipientChipTests {
    @Test("a well-formed address is valid")
    func validAddress() {
        let chip = RecipientChip(raw: "bea@x.com")
        #expect(chip.isValid)
        #expect(chip.address?.email == "bea@x.com")
    }

    @Test("a well-formed name-address pair is valid")
    func validNameAddress() {
        let chip = RecipientChip(raw: "Bea Smith <bea@x.com>")
        #expect(chip.isValid)
        #expect(chip.address?.displayLabel == "Bea Smith")
    }

    @Test("text that fails MailAddress(rfc5322:) is rejected, not silently accepted or dropped")
    func invalidAddressIsRejected() {
        let chip = RecipientChip(raw: "not-an-address")
        #expect(chip.isValid == false)
        #expect(chip.address == nil)
        // Still visible — the raw text is preserved for the chip to display as invalid.
        #expect(chip.raw == "not-an-address")
    }

    @Test("Send is disabled with zero valid recipients")
    func disabledWithZeroValid() {
        #expect(ComposeValidation.canSend([]) == false)
        #expect(ComposeValidation.canSend([RecipientChip(raw: "garbage")]) == false)
    }

    @Test("Send is enabled with exactly one valid recipient")
    func enabledWithOneValid() {
        #expect(ComposeValidation.canSend([RecipientChip(raw: "bea@x.com")]))
        // Even mixed with an invalid chip alongside it.
        #expect(ComposeValidation.canSend([RecipientChip(raw: "garbage"), RecipientChip(raw: "bea@x.com")]))
    }

    @Test("validAddresses excludes invalid chips")
    func validAddressesExcludesInvalid() {
        let addresses = ComposeValidation.validAddresses(
            [RecipientChip(raw: "garbage"), RecipientChip(raw: "bea@x.com")])
        #expect(addresses.map(\.email) == ["bea@x.com"])
    }
}
