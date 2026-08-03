import Foundation

/// The named times a scheduled send is actually wanted for.
///
/// A raw `DatePicker` makes the common case — "not now, tonight" — cost four
/// interactions and an arithmetic decision the user should not have to make.
/// These are the four that cover nearly all of it; the picker stays for
/// everything else.
///
/// Pure and clock-injected: `now` and `calendar` are parameters so the whole
/// thing is testable without waiting for Monday.
public enum SchedulePresets {
    public struct Preset: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let date: Date

        public init(id: String, title: String, date: Date) {
            self.id = id; self.title = title; self.date = date
        }
    }

    /// Hour-of-day each preset targets, in the user's own calendar/timezone —
    /// never UTC, since "tomorrow morning" is a local idea.
    static let eveningHour = 20
    static let morningHour = 9

    /// The presets, newest-first, every one of them strictly in the future.
    ///
    /// A preset whose time has already passed today rolls to the next day
    /// rather than being offered as a past instant — `Outbox` would treat a
    /// past `sendAt` as due immediately, which is the opposite of what
    /// "tonight" means at 11pm.
    public static func presets(now: Date, calendar: Calendar = .current) -> [Preset] {
        var out: [Preset] = [
            Preset(id: "hour", title: "In an hour", date: now.addingTimeInterval(3600)),
        ]
        if let tonight = nextOccurrence(ofHour: eveningHour, after: now, calendar: calendar,
                                       sameDayOnly: true) {
            out.append(Preset(id: "tonight", title: "Tonight", date: tonight))
        }
        if let morning = nextOccurrence(ofHour: morningHour, after: now, calendar: calendar,
                                       sameDayOnly: false, minimumDayOffset: 1) {
            out.append(Preset(id: "tomorrow", title: "Tomorrow morning", date: morning))
        }
        if let monday = nextWeekday(2, hour: morningHour, after: now, calendar: calendar) {
            out.append(Preset(id: "monday", title: "Monday 9am", date: monday))
        }
        return out
    }

    /// `hour:00` on the soonest day at or after `after` that makes it strictly
    /// future. `sameDayOnly` distinguishes "tonight" (today if it has not
    /// passed, otherwise not offered at all) from a preset that is allowed to
    /// roll forward; `minimumDayOffset` forces "tomorrow" to actually be
    /// tomorrow even when called at 3am.
    static func nextOccurrence(ofHour hour: Int, after: Date, calendar: Calendar,
                               sameDayOnly: Bool, minimumDayOffset: Int = 0) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: after)
        components.hour = hour
        components.minute = 0
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }
        if minimumDayOffset > 0 {
            guard let shifted = calendar.date(byAdding: .day, value: minimumDayOffset,
                                              to: candidate) else { return nil }
            candidate = shifted
        }
        if candidate <= after {
            guard !sameDayOnly else { return nil }
            return calendar.date(byAdding: .day, value: 1, to: candidate)
        }
        return candidate
    }

    /// `hour:00` on the next `weekday` (1 = Sunday, per `Calendar`) strictly
    /// after `after`. Called on a Monday morning before 9 this returns TODAY,
    /// which is right — "Monday 9am" means the next one, and that is it.
    static func nextWeekday(_ weekday: Int, hour: Int, after: Date,
                            calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(after: after, matching: components,
                                 matchingPolicy: .nextTime, direction: .forward)
    }
}
