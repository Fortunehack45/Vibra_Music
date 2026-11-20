import Foundation

// Ports the period half of data/stats/ListeningStats.kt (ReplayPeriod).

/// How far back a Replay reaches: this calendar month, this calendar year, or everything kept.
///
/// Months and years rather than a date range, because that is the granularity the listening is
/// actually kept at — one JSON file per calendar month. A "last 30 days" chip would have to be
/// answered from monthly totals, which would make it a lie for the first thirty days of every
/// month.
public enum ReplayPeriod: String, Codable, Hashable, Sendable, CaseIterable {
    case thisMonth = "THIS_MONTH"
    case thisYear = "THIS_YEAR"
    case allTime = "ALL_TIME"

    /// The chip titles, in English. The app localizes them (Android: `this_month` etc.).
    public var chipTitle: String {
        switch self {
        case .thisMonth: return "This month"
        case .thisYear: return "This year"
        case .allTime: return "All time"
        }
    }

    /// Whether the month `key` (`"YYYY-MM"`) belongs to this period on `today`.
    public func covers(monthKey: String, today: ReplayMonth) -> Bool {
        guard let month = ReplayMonth(key: monthKey) else { return false }
        switch self {
        case .thisMonth: return month == today
        case .thisYear: return month.year == today.year
        case .allTime: return true
        }
    }

    /// The heading for the period on `today`: "August 2026", "2026", or "All time".
    ///
    /// The month name comes from `locale` and its first letter is uppercased, matching Android's
    /// `localizedLabel`, which title-cases because some locales spell month names lowercase.
    public func label(today: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch self {
        case .thisMonth:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.dateFormat = "MMMM yyyy"
            let text = formatter.string(from: today)
            guard let first = text.first else { return text }
            return String(first).uppercased(with: locale) + text.dropFirst()
        case .thisYear:
            return String(calendar.component(.year, from: today))
        case .allTime:
            return "All time"
        }
    }
}

/// One calendar month, the granularity listening buckets are stored at.
///
/// The file for a month is named `"YYYY-MM.json"`, exactly as on Android, so a backup exported on
/// either platform restores on the other.
public struct ReplayMonth: Hashable, Sendable, Comparable, Strideable {
    public var year: Int
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// Parses `"YYYY-MM"`, or nil for anything else (including a filename with an extension).
    public init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
              parts[0].count == 4, parts[1].count == 2, (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// Parses `"YYYY-MM.json"` file names, nil for anything else.
    public init?(fileName: String) {
        guard fileName.hasSuffix(".json") else { return nil }
        self.init(key: String(fileName.dropLast(5)))
    }

    public init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month], from: date)
        self.year = components.year ?? 2000
        self.month = components.month ?? 1
    }

    /// `"YYYY-MM"`, the bucket key and file base name.
    public var key: String { String(format: "%04d-%02d", year, month) }

    /// `"MM/YY"` of the month, the "member since" date embossed on the Replay card: the first
    /// month this device recorded anything, all-time rather than the open period's own first
    /// month, so switching chips to This month doesn't announce a new membership.
    public var memberSince: String { String(format: "%02d/%02d", month, year % 100) }

    public static func < (lhs: ReplayMonth, rhs: ReplayMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    public func distance(to other: ReplayMonth) -> Int {
        (other.year - year) * 12 + (other.month - month)
    }

    public func advanced(by n: Int) -> ReplayMonth {
        let total = (year * 12 + (month - 1)) + n
        return ReplayMonth(year: total / 12, month: total % 12 + 1)
    }
}
