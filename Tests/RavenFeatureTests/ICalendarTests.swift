import Testing
import Foundation
@testable import RavenFeature

/// A naive line-split parser gets two things wrong: folded continuation
/// lines (beginning with a space or tab) and escaped `TEXT` values. These
/// tests pin both, plus the all-day/timezone `DTSTART` split.
@Suite("iCalendar parsing")
struct ICalendarTests {

    @Test("a folded continuation line is rejoined before parsing")
    func unfoldsContinuationLines() {
        let ics = "BEGIN:VEVENT\r\nSUMMARY:This is a very long summary that con\r\n tinues here\r\nEND:VEVENT"
        let lines = ICalendar.unfold(ics)
        let summaryLine = lines.first { $0.hasPrefix("SUMMARY:") }
        #expect(summaryLine == "SUMMARY:This is a very long summary that continues here")
    }

    @Test("escaped commas, semicolons, backslashes and newlines decode correctly")
    func unescapesText() {
        #expect(ICalendar.unescapeText("Team\\, sync\\; standup") == "Team, sync; standup")
        #expect(ICalendar.unescapeText("line one\\nline two") == "line one\nline two")
        #expect(ICalendar.unescapeText("back\\\\slash") == "back\\slash")
    }

    @Test("a request with a timezone-bearing DTSTART parses summary, times, location, organizer, attendees")
    func parsesTimezoneEvent() {
        let ics = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:event-1
        SUMMARY:Team sync\\, planning
        LOCATION:Conference Room A
        DTSTART;TZID=America/New_York:20260810T140000
        DTEND;TZID=America/New_York:20260810T150000
        ORGANIZER;CN=Bea Smith:mailto:bea@example.com
        ATTENDEE;CN=Cal Jones:mailto:cal@example.com
        ATTENDEE:mailto:dee@example.com
        END:VEVENT
        END:VCALENDAR
        """
        guard let invite = ICalendar.parseFirstEvent(ics) else {
            Issue.record("failed to parse"); return
        }
        #expect(invite.method == .request)
        #expect(invite.uid == "event-1")
        #expect(invite.summary == "Team sync, planning")
        #expect(invite.location == "Conference Room A")
        #expect(invite.isAllDay == false)
        #expect(invite.organizer?.email == "bea@example.com")
        #expect(invite.organizer?.name == "Bea Smith")
        #expect(invite.attendees.count == 2)
        #expect(invite.attendees.first?.name == "Cal Jones")
        #expect(invite.attendees.last?.email == "dee@example.com")
        #expect(invite.end != nil)
    }

    @Test("an all-day DTSTART (VALUE=DATE) parses as all-day with no time component")
    func parsesAllDayEvent() {
        let ics = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:event-2
        SUMMARY:Company holiday
        DTSTART;VALUE=DATE:20260901
        END:VEVENT
        END:VCALENDAR
        """
        guard let invite = ICalendar.parseFirstEvent(ics) else {
            Issue.record("failed to parse"); return
        }
        #expect(invite.isAllDay)
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: invite.start)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 1)
    }

    @Test("a missing DTSTART fails to parse rather than producing a garbage event")
    func missingDTStartFails() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:No start\r\nEND:VEVENT\r\nEND:VCALENDAR"
        #expect(ICalendar.parseFirstEvent(ics) == nil)
    }
}
