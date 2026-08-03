import Testing
import Foundation
@testable import RavenFeature

/// RSVP-by-email: the reply must carry `METHOD:REPLY`, the chosen
/// `PARTSTAT` on the responding attendee, and be addressed to the invite's
/// organizer — no `EventKit`/`Contacts` access involved on either side.
@Suite("Calendar RSVP")
struct CalendarRSVPTests {
    private func invite() -> CalendarInvite {
        CalendarInvite(method: .request, uid: "event-1", summary: "Team sync",
                       location: nil,
                       organizer: CalendarPerson(name: "Bea Smith", email: "bea@example.com"),
                       attendees: [], start: Date(), end: nil, isAllDay: false,
                       rawDTStart: "20260810T140000", rawDTStartParams: ["TZID": "America/New_York"])
    }

    @Test("an accepted RSVP is addressed to the organizer and carries METHOD:REPLY with PARTSTAT=ACCEPTED")
    func acceptedReply() throws {
        let reply = try #require(CalendarRSVP.makeReply(to: invite(), partstat: .accepted,
                                                         attendeeEmail: "me@example.com",
                                                         attendeeName: "Me"))
        #expect(reply.to.map(\.email) == ["bea@example.com"])
        let ics = try #require(reply.icsReply?.icsText)
        #expect(ics.contains("METHOD:REPLY"))
        #expect(ics.contains("PARTSTAT=ACCEPTED"))
        #expect(ics.contains("mailto:me@example.com"))
        #expect(ics.contains("UID:event-1"))
        // The original DTSTART (and its TZID) is echoed back so the
        // organizer's calendar can match this reply to the right occurrence.
        #expect(ics.contains("DTSTART;TZID=America/New_York:20260810T140000"))
    }

    @Test("tentative and declined RSVPs carry their own PARTSTAT")
    func tentativeAndDeclined() throws {
        let tentative = try #require(CalendarRSVP.makeReply(to: invite(), partstat: .tentative,
                                                             attendeeEmail: "me@example.com",
                                                             attendeeName: nil))
        #expect(tentative.icsReply?.icsText.contains("PARTSTAT=TENTATIVE") == true)

        let declined = try #require(CalendarRSVP.makeReply(to: invite(), partstat: .declined,
                                                            attendeeEmail: "me@example.com",
                                                            attendeeName: nil))
        #expect(declined.icsReply?.icsText.contains("PARTSTAT=DECLINED") == true)
    }

    @Test("an invite with no organizer cannot produce an RSVP")
    func noOrganizerRefuses() {
        let noOrganizer = CalendarInvite(method: .request, uid: "e2", summary: "x", location: nil,
                                         organizer: nil, attendees: [], start: Date(), end: nil,
                                         isAllDay: false, rawDTStart: "", rawDTStartParams: [:])
        #expect(CalendarRSVP.makeReply(to: noOrganizer, partstat: .accepted,
                                       attendeeEmail: "me@example.com", attendeeName: nil) == nil)
    }

    @Test("the generated RSVP round-trips through the same rfc822 builder attachments use")
    func rsvpSurvivesRFC822() throws {
        let reply = try #require(CalendarRSVP.makeReply(to: invite(), partstat: .accepted,
                                                         attendeeEmail: "me@example.com",
                                                         attendeeName: "Me"))
        let raw = GmailMapping.decodeBase64URL(GmailProvider.rfc822(reply)) ?? ""
        #expect(raw.contains("Content-Type: text/calendar; method=REPLY"))
        #expect(raw.contains("Content-Type: multipart/mixed;"))
    }
}
