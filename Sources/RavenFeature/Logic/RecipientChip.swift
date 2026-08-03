import Foundation

/// One committed chip in Compose's To/Cc field. Committing (return/comma/tab)
/// runs the typed text through `MailAddress(rfc5322:)` immediately, so an
/// invalid address is never silently accepted as if it were sendable, and
/// never silently dropped either — it stays on screen, visibly marked invalid
/// via `isValid`, until the human fixes or removes it.
public struct RecipientChip: Equatable, Sendable {
    /// Exactly what the human typed, unmodified — shown on the chip so a typo
    /// is visible, rather than swallowed into a generic "invalid" label.
    public let raw: String
    /// `nil` when `raw` failed `MailAddress(rfc5322:)`.
    public let address: MailAddress?

    public init(raw: String) {
        self.raw = raw
        self.address = MailAddress(rfc5322: raw)
    }

    public var isValid: Bool { address != nil }
    /// What a chip should show — the parsed display label when valid (so
    /// "bea@x.com" and "Bea Smith <bea@x.com>" render consistently), the raw
    /// typed text otherwise.
    public var displayLabel: String { address?.displayLabel ?? raw }
}

/// Whether Compose's Send button may be pressed, and what actually gets sent.
/// Kept separate from `ComposeSurface` so it is testable without SwiftUI.
public enum ComposeValidation {
    /// Send is enabled once there is at least one VALID recipient — an
    /// all-invalid or empty chip list must not enable it, matching the
    /// pre-chip behaviour where `recipients.isEmpty` gated the button.
    public static func canSend(_ chips: [RecipientChip]) -> Bool {
        chips.contains { $0.isValid }
    }

    /// The addresses that would actually be sent to — invalid chips are
    /// excluded here too, never handed to `OutgoingMessage`.
    public static func validAddresses(_ chips: [RecipientChip]) -> [MailAddress] {
        chips.compactMap(\.address)
    }
}
