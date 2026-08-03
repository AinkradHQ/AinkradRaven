import Foundation

/// Metadata for one Gmail attachment part. Deliberately carries no bytes —
/// those are fetched on demand (see `MailProvider.fetchAttachment`) and never
/// cached to disk, so a `MailMessage` stays cheap to store and index.
public struct MailAttachment: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let filename: String
    public let mimeType: String
    public let size: Int

    public init(attachmentID: String, filename: String, mimeType: String, size: Int) {
        self.attachmentID = attachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}
