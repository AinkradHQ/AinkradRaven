import Foundation

/// Gmail rejects a message over 25MB (its own stated limit on the *encoded*
/// RFC 822 message, not the sum of raw attachment bytes). A message that
/// exceeds this is refused HERE — before it is ever queued — rather than
/// being handed to the outbox where it would only fail on transmit and land
/// as a dead letter the user has to notice and clean up. Refusing early means
/// nothing is queued at all: the composer keeps the typed text and the
/// attachment chips exactly as `ComposeSurface`'s other early refusals do.
enum AttachmentSizeGuard {
    /// Gmail's own limit. Kept slightly conservative (24.5MB rather than a
    /// bare 25,000,000) because base64 inflates raw bytes by ~4/3 and the
    /// surrounding MIME structure (headers, boundaries, the text parts) adds
    /// a little more on top — this guard checks attachment bytes alone, so a
    /// small margin avoids refusing well under the real ceiling while still
    /// queueing a message that is Gmail's problem, not ours, at the boundary.
    static let maxEncodedMessageBytes = 24_500_000

    /// `nil` when the message is within budget; otherwise a user-facing
    /// message naming the overage, safe to show directly in a banner.
    static func refusalMessage(for attachments: [OutgoingAttachment]) -> String? {
        let rawTotal = attachments.reduce(0) { $0 + $1.data.count }
        // Base64 encodes 3 raw bytes as 4 output characters.
        let encodedTotal = (rawTotal + 2) / 3 * 4
        guard encodedTotal > maxEncodedMessageBytes else { return nil }
        let rawMB = Double(rawTotal) / 1_000_000
        let limitMB = Double(maxEncodedMessageBytes) / 1_000_000 * 3 / 4
        return String(format: "These attachments total %.1f MB, which is too large for Gmail " +
                      "to send (the limit is about %.0f MB of raw attachment data). Remove one " +
                      "or more files before sending; nothing has been queued.", rawMB, limitMB)
    }
}
