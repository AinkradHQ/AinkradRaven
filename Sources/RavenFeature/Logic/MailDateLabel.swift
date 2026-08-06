import Foundation

/// The compact date a thread row shows in its trailing column.
///
/// Mail-client convention, because an inbox row has room for about six
/// characters and a full `.abbreviated`+`.shortened` stamp ("3 Mar 2026 at
/// 09:14") crowds out the snippet that actually tells the user what the thread
/// is: today's mail shows a time, this year's shows a day and month, anything
/// older shows a year. Extracted from the view so the boundary cases (midnight,
/// New Year) are testable rather than eyeballed.
public enum MailDateLabel {
    /// - Parameter now: injected so the boundaries can be tested; callers in
    ///   the UI pass the real current date.
    public static func short(for date: Date, now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        // The style is built from the SAME calendar the day/year comparisons
        // use — including its time zone and locale. `.dateTime` and
        // `formatted(date:time:)` always render in the autoupdating current
        // calendar, which would let the label disagree with the branch that
        // chose it (a message at 23:00 UTC is "yesterday" by a UTC calendar and
        // "today" by a +03:00 one).
        let base = Date.FormatStyle(date: nil, time: nil,
                                    locale: calendar.locale ?? .current,
                                    calendar: calendar,
                                    timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(base.hour().minute())
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(base.day().month(.abbreviated))
        }
        // A year alone, not a full date: at this age the row only needs to say
        // "this is old", and the exact day is available in the thread itself.
        return date.formatted(base.year())
    }
}
