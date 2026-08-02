import Foundation

/// Index documents are sharded by UTC year-month so the inbox loads only the
/// months it displays instead of every thread ever synced.
public enum MonthShard {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    public static func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Every month key from `start` to `end`, inclusive. Empty when inverted.
    public static func keys(from start: Date, to end: Date) -> [String] {
        guard start <= end else { return [] }
        let calendar = self.calendar
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        var keys: [String] = []
        while cursor <= end {
            keys.append(key(for: cursor))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }
}
