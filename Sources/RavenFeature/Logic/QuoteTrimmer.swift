import Foundation

/// Splits a reply into what the sender wrote and the trailer they quoted, so
/// the thread view can collapse the second part.
public enum QuoteTrimmer {
    private static let attributionPattern =
        "(?m)^\\s*(On .+wrote:|-----Original Message-----|_{5,}|From: .+)\\s*$"

    /// True when one line on its own is a quote attribution (`On … wrote:`,
    /// `-----Original Message-----`, a rule of underscores, or `From: …`).
    ///
    /// Exposed so `QuotedRegion` can peel the attribution off the front of the
    /// quoted trailer and render it as its own paragraph, using the SAME
    /// pattern that decided where the trailer began — two patterns would drift.
    static func isAttributionLine(_ line: String) -> Bool {
        line.range(of: attributionPattern, options: .regularExpression) != nil
    }

    public static func split(_ body: String) -> (visible: String, quoted: String?) {
        if let range = body.range(of: attributionPattern, options: .regularExpression) {
            let visible = String(body[body.startIndex..<range.lowerBound])
            let quoted = String(body[range.lowerBound...])
            return (visible.trimmingCharacters(in: .whitespacesAndNewlines), quoted)
        }
        let lines = body.components(separatedBy: "\n")
        if let firstQuoted = lines.firstIndex(where: { $0.hasPrefix(">") }) {
            let visible = lines[..<firstQuoted].joined(separator: "\n")
            let quoted = lines[firstQuoted...].joined(separator: "\n")
            return (visible.trimmingCharacters(in: .whitespacesAndNewlines), quoted)
        }
        return (body, nil)
    }
}
