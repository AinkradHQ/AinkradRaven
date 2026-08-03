import Testing
import Foundation
@testable import RavenFeature

@Suite("Inbox row date label")
struct MailDateLabelTests {
    /// A fixed calendar, time zone AND locale so these assertions depend on
    /// none of the three — the locale in particular decides the digits (an
    /// Arabic locale renders "9" as "٩").
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("today shows a time, not a date")
    func todayShowsTime() {
        let now = date(2026, 3, 14, 17)
        let label = MailDateLabel.short(for: date(2026, 3, 14, 9), now: now, calendar: calendar)
        // Locale decides the exact rendering; what matters is that it is a
        // clock time (contains the hour) and carries no month name.
        #expect(label.contains("9"))
        #expect(!label.lowercased().contains("mar"))
    }

    @Test("yesterday is a day+month even one minute over the midnight boundary")
    func midnightBoundary() {
        let now = date(2026, 3, 14, 0)
        let label = MailDateLabel.short(for: date(2026, 3, 13, 23), now: now, calendar: calendar)
        #expect(label.contains("13"))
    }

    @Test("a previous year collapses to just the year")
    func previousYearShowsYear() {
        let now = date(2026, 1, 1, 0)
        // One hour earlier in real time, but a different year — must not read
        // as "today" or as a bare day+month with no year at all.
        let label = MailDateLabel.short(for: date(2025, 12, 31, 23), now: now, calendar: calendar)
        #expect(label.contains("2025"))
    }
}
