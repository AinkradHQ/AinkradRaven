import Foundation
import Testing

/// Reads an assembled RFC 822 message back apart, so a test can assert on the
/// structure a recipient's client would actually see rather than on substrings
/// of the source.
///
/// Deliberately does NOT reuse `RFC822Builder`, `MIMEHeader` or any other
/// production type: an expectation computed by calling the code it checks
/// passes however that code is wired. Everything here is a hand-rolled parse of
/// the transmitted text.
enum MIMEProbe {
    /// Every `Content-Type` value in order of appearance, with the `boundary`
    /// parameter (a fresh UUID per call) removed so the sequence is stable.
    /// Returned as a list so a test can compare the WHOLE part sequence and
    /// thereby pin that nothing sits between two expected parts.
    static func contentTypes(_ raw: String) -> [String] {
        headerValues(raw, named: "Content-Type").map { value in
            guard let range = value.range(of: "; boundary=") else { return value }
            return String(value[..<range.lowerBound])
        }
    }

    static func transferEncodings(_ raw: String) -> [String] {
        headerValues(raw, named: "Content-Transfer-Encoding")
    }

    private static func headerValues(_ raw: String, named name: String) -> [String] {
        let prefix = "\(name): "
        return raw.components(separatedBy: "\r\n")
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    /// The decoded bytes of every `text/plain` and `text/html` part, in order.
    /// Bytes rather than `String` so a test can compare them byte-for-byte
    /// without Unicode equivalence smoothing over a difference.
    static func decodedPartData(_ raw: String) -> [Data] {
        var parts: [Data] = []
        let lines = raw.components(separatedBy: "\r\n")
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("Content-Type: text/plain")
                    || lines[index].hasPrefix("Content-Type: text/html") else {
                index += 1
                continue
            }
            // Past the rest of this part's headers, then the blank line.
            var cursor = index + 1
            while cursor < lines.count && !lines[cursor].isEmpty { cursor += 1 }
            cursor += 1
            var encoded = ""
            while cursor < lines.count && !lines[cursor].hasPrefix("--raven-") {
                encoded += lines[cursor]
                cursor += 1
            }
            // Advanced BEFORE the guard below: a `continue` that skipped this
            // would re-scan the same part forever, and a probe that hangs is
            // strictly worse than one that reports a wrong answer.
            index = cursor
            // A part that will not decode is RECORDED, never defaulted away.
            // `?? Data()` would turn a broken message into an empty part, and
            // every expectation in this file compares against non-empty
            // content — so the failure would surface as a confusing inequality,
            // or not at all once someone writes an empty expectation.
            guard let decoded = Data(base64Encoded: encoded) else {
                Issue.record("a text part's base64 did not decode: \(encoded.prefix(80))")
                continue
            }
            parts.append(decoded)
        }
        return parts
    }

    static func decodedParts(_ raw: String) -> [String] {
        decodedPartData(raw).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Each `raven-<uuid>` token in order of first appearance.
    static func boundaryTokens(_ raw: String) -> [String] {
        var seen: [String] = []
        for chunk in raw.components(separatedBy: "raven-").dropFirst() {
            let token = "raven-" + chunk.prefix(36)
            if !seen.contains(token) { seen.append(token) }
        }
        return seen
    }

    /// Replaces each distinct boundary token with a stable index, so two runs
    /// over the same input become comparable byte-for-byte.
    static func normalisedBoundaries(_ raw: String) -> String {
        var result = raw
        for (index, token) in boundaryTokens(raw).enumerated() {
            result = result.replacingOccurrences(of: token, with: "raven-BOUNDARY-\(index)")
        }
        return result
    }
}
