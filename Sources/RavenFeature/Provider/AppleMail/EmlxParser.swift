import Foundation

/// One parsed `.emlx` file: Mail.app's on-disk message format — a
/// byte-count line, that many raw RFC822 bytes, then a plist trailer
/// carrying flags (`read`, `flagged`, and others that vary by Mail.app
/// version).
struct EmlxMessage {
    let message: RFC822Message
    let isRead: Bool
    let isFlagged: Bool
}

/// Parses one `.emlx` file's bytes. Tolerant by design: a byte-count line
/// that isn't a plain decimal integer, a declared count longer than what is
/// actually there, or a corrupt/truncated plist trailer all make `parse`
/// return `nil` rather than throw — `AppleMailImporter` skips a `nil` and
/// continues the batch, so one bad file never aborts an import.
enum EmlxParser {
    static func parse(_ data: Data) -> EmlxMessage? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let countLine = data[data.startIndex..<newline]
        guard let countString = String(data: countLine, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let byteCount = Int(countString), byteCount >= 0 else {
            return nil
        }

        let messageStart = data.index(after: newline)
        guard data.distance(from: messageStart, to: data.endIndex) >= byteCount else {
            // Declared more bytes than the file actually has left — truncated.
            return nil
        }
        let messageEnd = data.index(messageStart, offsetBy: byteCount)
        let messageBytes = data.subdata(in: messageStart..<messageEnd)
        let rfc822 = RFC822Message.parse(messageBytes)

        // The plist trailer is whatever remains after the message bytes.
        // Tolerant of a missing trailer (some real-world `.emlx` files carry
        // none) — flags simply default to "unread, unflagged" rather than
        // the whole file being rejected, since the message itself parsed
        // fine.
        let trailer = data.subdata(in: messageEnd..<data.endIndex)
        var isRead = false
        var isFlagged = false
        if !trailer.isEmpty {
            guard let plist = try? PropertyListSerialization.propertyList(
                from: trailer, options: [], format: nil) as? [String: Any] else {
                // A trailer is present but corrupt/truncated — the message
                // bytes themselves were fine, but Mail.app's own contract for
                // this format is "message + trailer", and a corrupt trailer
                // means this file did not decode according to that contract.
                return nil
            }
            let flags = (plist["flags"] as? [String: Any]) ?? plist
            isRead = (flags["read"] as? Bool) ?? (flags["read"] as? Int == 1) ?? false
            isFlagged = (flags["flagged"] as? Bool) ?? (flags["flagged"] as? Int == 1) ?? false
        }

        return EmlxMessage(message: rfc822, isRead: isRead, isFlagged: isFlagged)
    }
}
