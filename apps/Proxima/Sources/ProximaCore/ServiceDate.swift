import Foundation

/// A calendar date, with no time and no zone.
///
/// GTFS talks about *service days*, which are not days: a service day can be
/// 23 or 25 hours long and can extend past midnight into the next date. Mixing
/// that up with `Date` — an instant — is how most of the arithmetic in this
/// app goes quietly wrong, so the two are different types and the conversion
/// between them happens in exactly one place, `Timetable.serviceDayOrigin`.
///
/// Weekday and day arithmetic are computed rather than delegated to
/// `Calendar`, so they behave identically on watchOS and on the Linux runner
/// where `swift test` executes.
public struct ServiceDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// GTFS writes dates as `YYYYMMDD` with no separators.
    public init?(gtfs text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 8, trimmed.allSatisfy(\.isNumber) else { return nil }
        let digits = Array(trimmed)
        guard let year = Int(String(digits[0..<4])),
              let month = Int(String(digits[4..<6])),
              let day = Int(String(digits[6..<8])),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public static func < (lhs: ServiceDate, rhs: ServiceDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: - Civil date arithmetic

    /// Days since 1970-01-01, by Howard Hinnant's `days_from_civil`.
    ///
    /// Exact for every proleptic Gregorian date and free of the leap-year
    /// special cases a hand-rolled version gets wrong in 2100.
    public var daysSinceEpoch: Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    public init(daysSinceEpoch: Int) {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        self.init(year: y + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    public func adding(days: Int) -> ServiceDate {
        ServiceDate(daysSinceEpoch: daysSinceEpoch + days)
    }

    /// Monday is 0, matching the column order of GTFS `calendar.txt`.
    ///
    /// 1970-01-01 was a Thursday, which is index 3.
    public var weekdayIndex: Int {
        let raw = (daysSinceEpoch + 3) % 7
        return raw < 0 ? raw + 7 : raw
    }
}

/// Seconds since the start of a service day.
///
/// GTFS times may exceed 24 hours: a trip departing at `25:30:00` on Saturday
/// leaves at half past one on Sunday morning and belongs to Saturday's
/// service. Storing this as a wall-clock time of day loses the distinction and
/// takes every late-night departure off the board.
public enum GTFSTime {
    /// `"25:30:00"` becomes 91,800.
    ///
    /// Returns `nil` for a blank time, which GTFS permits at non-timepoint
    /// stops and the caller must interpolate. Throws on anything else: a
    /// departure board that silently drops malformed rows is a departure board
    /// that silently loses trains.
    public static func parse(_ value: String) throws -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Int(parts[2])
        else { throw FeedError("not a GTFS time: \(value)") }
        guard hours >= 0, (0...59).contains(minutes), (0...59).contains(seconds) else {
            throw FeedError("out of range GTFS time: \(value)")
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Back to `HH:MM:SS`, hours unbounded. Used when writing a slice.
    public static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

public struct FeedError: LocalizedError, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
    /// So the phone app can show this to a person instead of the struct's
    /// default reflection dump.
    public var errorDescription: String? { description }
}
