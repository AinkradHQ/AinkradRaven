import Foundation

/// The signature separator, and the one way to find it again in a composed
/// body.
///
/// `SendAttempt` appends `body + "\n-- \n" + signature` to `bodyText` — the
/// plain-text part is required to stay exactly that, byte for byte, because
/// `-- ` on a line of its own (dash dash space) is the convention every mail
/// client uses to trim a signature on reply.
///
/// That same string, handed to a Markdown parser, is a **setext h2
/// underline**: `--` under `Thanks for the update.` turns that line into a
/// heading block, silently restructuring the last line of the user's body and
/// deleting the separator. So the HTML part must never let the parser see the
/// sigdash as structure: `split` recovers the two halves so each can be
/// rendered on its own and joined with explicit markup.
public enum Signature {
    /// Conventional sigdash: a line consisting of exactly `-- `.
    public static let sigdash = "\n-- \n"

    /// Splits a composed body into its body and signature halves at the LAST
    /// sigdash — the one `SendAttempt` appended. An earlier `\n-- \n` typed by
    /// the user inside the body stays in the body half, where it belongs.
    /// Returns a nil signature when there is no sigdash at all.
    public static func split(_ composed: String) -> (body: String, signature: String?) {
        guard let range = composed.range(of: sigdash, options: .backwards) else {
            return (composed, nil)
        }
        return (String(composed[composed.startIndex..<range.lowerBound]),
                String(composed[range.upperBound...]))
    }
}
