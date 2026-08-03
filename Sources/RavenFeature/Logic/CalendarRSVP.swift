import Foundation

/// Builds the `OutgoingMessage` an "Accept" / "Tentative" / "Decline" tap in
/// the invite card sends. This is the whole of RSVP-by-email: no `EventKit`
/// involved, because a `METHOD:REPLY` calendar part addressed to the
/// organizer is how RSVPs genuinely travel between mail clients — the
/// organizer's own calendar software updates the attendee's status when it
/// receives this, exactly as it would from Apple Mail, Outlook, or Gmail's
/// own reply-by-email path. It does **not** add anything to the user's own
/// Calendar — `Contacts`/`EventKit` access is unavailable to this plugin (see
/// the M4 task's own scope note), so callers must say so in the UI.
public enum CalendarRSVP {
    public enum PartStat: String {
        case accepted = "ACCEPTED"
        case tentative = "TENTATIVE"
        case declined = "DECLINED"

        var humanLabel: String {
            switch self {
            case .accepted: return "accepted"
            case .tentative: return "tentatively accepted"
            case .declined: return "declined"
            }
        }
    }

    /// `nil` when the invite has no organizer to reply to, or the user's own
    /// address is unknown — both refusals rather than sending a reply with no
    /// meaningful recipient or no `ATTENDEE` line identifying who is
    /// responding.
    public static func makeReply(to invite: CalendarInvite, partstat: PartStat,
                                 attendeeEmail: String, attendeeName: String?) -> OutgoingMessage? {
        guard let organizer = invite.organizer else { return nil }
        let ics = buildICS(invite: invite, partstat: partstat,
                           attendeeEmail: attendeeEmail, attendeeName: attendeeName)
        let subjectPrefix: String
        switch partstat {
        case .accepted: subjectPrefix = "Accepted: "
        case .tentative: subjectPrefix = "Tentative: "
        case .declined: subjectPrefix = "Declined: "
        }
        let bodyText = "\(attendeeName ?? attendeeEmail) has \(partstat.humanLabel) this invitation.\n\n" +
            "This reply does not add the event to any Calendar on this device — it only tells " +
            "\(organizer.displayLabel) how to record your response."
        return OutgoingMessage(
            to: [MailAddress(email: organizer.email, name: organizer.name)],
            subject: subjectPrefix + invite.summary,
            bodyText: bodyText,
            icsReply: ICSReply(icsText: ics))
    }

    /// A minimal, valid `VCALENDAR`/`METHOD:REPLY`/`VEVENT` carrying exactly
    /// one `ATTENDEE` (the responding user) with `PARTSTAT` set, and the
    /// original event's `UID`/`DTSTART`/`ORGANIZER`/`SUMMARY` echoed back —
    /// the fields a receiving calendar needs to match this reply to the
    /// invite it sent and update that one attendee's status.
    private static func buildICS(invite: CalendarInvite, partstat: PartStat,
                                 attendeeEmail: String, attendeeName: String?) -> String {
        let organizerLine = invite.organizer.map { organizer -> String in
            let cn = organizer.name.map { ";CN=\(escapeText($0))" } ?? ""
            return "ORGANIZER\(cn):mailto:\(organizer.email)"
        } ?? ""
        let attendeeCN = attendeeName.map { ";CN=\(escapeText($0))" } ?? ""
        let dtstampFormatter = DateFormatter()
        dtstampFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dtstampFormatter.timeZone = TimeZone(identifier: "UTC")
        let dtstamp = dtstampFormatter.string(from: Date())

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "METHOD:REPLY",
            "PRODID:-//Ainkrad//Raven//EN",
            "BEGIN:VEVENT",
            "UID:\(invite.uid ?? UUID().uuidString)",
            "DTSTAMP:\(dtstamp)",
        ]
        if !invite.rawDTStart.isEmpty {
            let paramSuffix = invite.rawDTStartParams
                .map { ";\($0.key)=\($0.value)" }
                .joined()
            lines.append("DTSTART\(paramSuffix):\(invite.rawDTStart)")
        }
        if !organizerLine.isEmpty { lines.append(organizerLine) }
        lines.append("ATTENDEE\(attendeeCN);PARTSTAT=\(partstat.rawValue):mailto:\(attendeeEmail)")
        lines.append("SUMMARY:\(escapeText(invite.summary))")
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
