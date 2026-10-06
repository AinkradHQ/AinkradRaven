import Foundation
import Testing

@testable import RavenFeature

@Suite("SchedulePresets")
struct SchedulePresetsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    private func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    @Test("every preset is strictly in the future")
    func allFuture() {
        for moment in [
            "2026-08-03 07:15", "2026-08-03 13:00", "2026-08-03 21:30",
            "2026-08-08 23:59",
        ] {
            let now = date(moment)
            for preset in SchedulePresets.presets(now: now, calendar: calendar) {
                #expect(preset.date > now, "\(preset.id) at \(moment) was not in the future")
            }
        }
    }

    @Test("tonight is 8pm today when 8pm has not passed")
    func tonightToday() {
        let now = date("2026-08-03 13:00")
        let tonight = SchedulePresets.presets(now: now, calendar: calendar)
            .first { $0.id == "tonight" }
        #expect(components(tonight!.date).hour == 20)
        #expect(components(tonight!.date).day == 3)
    }

    @Test("tonight is not offered at all once 8pm has passed")
    func tonightGoneLate() {
        // Rolling "Tonight" to tomorrow night would be a label that lies.
        let now = date("2026-08-03 21:30")
        #expect(
            !SchedulePresets.presets(now: now, calendar: calendar)
                .contains { $0.id == "tonight" })
    }

    @Test("tomorrow morning is 9am the following day, even at 3am")
    func tomorrowMorning() {
        for (moment, expectedDay) in [("2026-08-03 03:00", 4), ("2026-08-03 22:00", 4)] {
            let preset = SchedulePresets.presets(now: date(moment), calendar: calendar)
                .first { $0.id == "tomorrow" }
            #expect(components(preset!.date).hour == 9)
            #expect(components(preset!.date).day == expectedDay)
        }
    }

    @Test("Monday 9am lands on a Monday at 9")
    func mondayNine() {
        // 2026-08-03 is itself a Monday; from 13:00 the next Monday 9am is the
        // 10th, and from 07:15 it is today.
        let fromAfternoon = SchedulePresets.presets(
            now: date("2026-08-03 13:00"),
            calendar: calendar
        )
        .first { $0.id == "monday" }!
        #expect(components(fromAfternoon.date).weekday == 2)
        #expect(components(fromAfternoon.date).hour == 9)
        #expect(components(fromAfternoon.date).day == 10)

        let fromEarly = SchedulePresets.presets(
            now: date("2026-08-03 07:15"),
            calendar: calendar
        )
        .first { $0.id == "monday" }!
        #expect(components(fromEarly.date).day == 3)
    }

    @Test("presets are uniquely identified so the UI can select one")
    func uniqueIDs() {
        let presets = SchedulePresets.presets(now: date("2026-08-03 13:00"), calendar: calendar)
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.count == 4)
    }
}
