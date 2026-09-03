import XCTest
@testable import AwqatCore

/// Cross-implementation validation.
///
/// Unit tests that only check the engine against itself would pass happily with a
/// sign error in the declination. So every expectation below is a published time
/// fetched from the AlAdhan API (api.aladhan.com), an independent implementation in
/// wide use, on 2026-09-03. Each case records the exact query that produced it so
/// the numbers can be re-derived rather than taken on trust.
///
/// Tolerance is one minute. Prayer timetables are published to the minute and
/// implementations differ in whether they round or truncate, so agreeing to within
/// a minute is the strongest claim that can honestly be made. Anything worse than
/// that indicates a real error in the astronomy, not a rounding difference.
final class ReferenceTimetableTests: XCTestCase {

    private static let toleranceSeconds: TimeInterval = 60

    private struct ReferenceCase {
        let name: String
        let query: String
        let coordinates: Coordinates
        let date: CalendarDate
        let method: CalculationMethod
        let asrSchool: AsrSchool
        let highLatitudeRule: HighLatitudeRule
        /// UTC offset the reference times are expressed in, in hours.
        let utcOffsetHours: Double
        /// Local clock times as "HH:MM" for fajr, sunrise, dhuhr, asr, maghrib, isha.
        let expected: [Prayer: String]
    }

    // AlAdhan's default `latitudeAdjustmentMethod` is ANGLE_BASED, so every case
    // below uses `.twilightAngle` to compare like with like.
    private static let cases: [ReferenceCase] = [
        ReferenceCase(
            name: "London, midsummer, Fajr and Isha both fall back to the twilight rule",
            query: "timings/15-06-2026?latitude=51.5074&longitude=-0.1278&method=3&school=0",
            coordinates: Coordinates(latitude: 51.5074, longitude: -0.1278),
            date: CalendarDate(year: 2026, month: 6, day: 15),
            method: .muslimWorldLeague,
            asrSchool: .standard,
            highLatitudeRule: .twilightAngle,
            utcOffsetHours: 1, // BST
            expected: [
                .fajr: "02:30", .sunrise: "04:43", .dhuhr: "13:01",
                .asr: "17:23", .maghrib: "21:19", .isha: "23:25"
            ]
        ),
        ReferenceCase(
            name: "New York, midwinter, ISNA angles",
            query: "timings/15-01-2026?latitude=40.7128&longitude=-74.0060&method=2&school=0",
            coordinates: Coordinates(latitude: 40.7128, longitude: -74.0060),
            date: CalendarDate(year: 2026, month: 1, day: 15),
            method: .northAmerica,
            asrSchool: .standard,
            highLatitudeRule: .twilightAngle,
            utcOffsetHours: -5, // EST
            expected: [
                .fajr: "05:58", .sunrise: "07:18", .dhuhr: "12:06",
                .asr: "14:33", .maghrib: "16:53", .isha: "18:14"
            ]
        ),
        ReferenceCase(
            name: "Jakarta, near the equator, Hanafi Asr",
            query: "timings/20-09-2026?latitude=-6.2088&longitude=106.8456&method=3&school=1",
            coordinates: Coordinates(latitude: -6.2088, longitude: 106.8456),
            date: CalendarDate(year: 2026, month: 9, day: 20),
            method: .muslimWorldLeague,
            asrSchool: .hanafi,
            highLatitudeRule: .twilightAngle,
            utcOffsetHours: 7,
            expected: [
                .fajr: "04:34", .sunrise: "05:43", .dhuhr: "11:46",
                .asr: "16:04", .maghrib: "17:49", .isha: "18:54"
            ]
        ),
        ReferenceCase(
            name: "Sydney, southern hemisphere winter",
            query: "timings/05-07-2026?latitude=-33.8688&longitude=151.2093&method=3&school=0",
            coordinates: Coordinates(latitude: -33.8688, longitude: 151.2093),
            date: CalendarDate(year: 2026, month: 7, day: 5),
            method: .muslimWorldLeague,
            asrSchool: .standard,
            highLatitudeRule: .twilightAngle,
            utcOffsetHours: 10, // AEST, no DST in July
            expected: [
                .fajr: "05:32", .sunrise: "07:01", .dhuhr: "12:00",
                .asr: "14:40", .maghrib: "16:59", .isha: "18:23"
            ]
        ),
        ReferenceCase(
            name: "Cairo, Egyptian angles, Hanafi Asr",
            query: "timings/12-11-2026?latitude=30.0444&longitude=31.2357&method=5&school=1",
            coordinates: Coordinates(latitude: 30.0444, longitude: 31.2357),
            date: CalendarDate(year: 2026, month: 11, day: 12),
            method: .egyptian,
            asrSchool: .hanafi,
            highLatitudeRule: .twilightAngle,
            utcOffsetHours: 2, // EET
            expected: [
                .fajr: "04:48", .sunrise: "06:18", .dhuhr: "11:39",
                .asr: "15:24", .maghrib: "17:00", .isha: "18:20"
            ]
        )
    ]

    func testAgreesWithPublishedTimetables() throws {
        for reference in Self.cases {
            var parameters = reference.method.parameters
            parameters.asrSchool = reference.asrSchool
            parameters.highLatitudeRule = reference.highLatitudeRule

            let times = try XCTUnwrap(
                PrayerTimes(
                    coordinates: reference.coordinates,
                    date: reference.date,
                    method: reference.method,
                    parameterOverride: parameters
                ),
                "engine returned nil for \(reference.name)"
            )

            for (prayer, clock) in reference.expected {
                let expected = try Self.instant(
                    localClock: clock,
                    on: reference.date,
                    utcOffsetHours: reference.utcOffsetHours
                )
                let actual = times.time(for: prayer)
                let delta = actual.timeIntervalSince(expected)
                XCTAssertLessThanOrEqual(
                    abs(delta),
                    Self.toleranceSeconds,
                    """
                    \(reference.name): \(prayer.displayName) off by \(Int(delta.rounded()))s
                    query: \(reference.query)
                    expected \(clock) local, got \(Self.clock(actual, utcOffsetHours: reference.utcOffsetHours))
                    """
                )
            }
        }
    }

    /// Umm al-Qura defines Isha as a fixed interval after Maghrib rather than by an
    /// angle. Checked separately because AlAdhan silently adds 30 minutes during
    /// Ramadan, which is a real Umm al-Qura rule the engine does not implement — it
    /// has no Hijri calendar. Asserting the plain 90-minute rule here documents
    /// that gap instead of hiding it.
    func testUmmAlQuraUsesFixedIntervalAfterMaghrib() throws {
        let date = CalendarDate(year: 2026, month: 3, day: 10)
        let times = try XCTUnwrap(
            PrayerTimes(
                coordinates: Coordinates(latitude: 21.4225, longitude: 39.8262),
                date: date,
                method: .ummAlQura
            )
        )
        // AlAdhan for this date: Maghrib 18:28 +03, Isha 20:28 with a documented
        // +30 Ramadan offset, so the un-adjusted rule is 18:28 + 90m = 19:58.
        let maghrib = try Self.instant(localClock: "18:28", on: date, utcOffsetHours: 3)
        let isha = try Self.instant(localClock: "19:58", on: date, utcOffsetHours: 3)

        XCTAssertLessThanOrEqual(abs(times.maghrib.timeIntervalSince(maghrib)), Self.toleranceSeconds)
        XCTAssertLessThanOrEqual(abs(times.isha.timeIntervalSince(isha)), Self.toleranceSeconds)
        XCTAssertEqual(times.isha.timeIntervalSince(times.maghrib), 90 * 60, accuracy: 1)
    }

    // MARK: - Helpers

    private static func instant(localClock: String, on date: CalendarDate, utcOffsetHours: Double) throws -> Date {
        let parts = localClock.split(separator: ":")
        guard parts.count == 2, let hour = Double(parts[0]), let minute = Double(parts[1]) else {
            throw XCTSkip("malformed reference clock \(localClock)")
        }
        let jd = julianDay(year: date.year, month: date.month, day: date.day)
        let utHours = hour + minute / 60 - utcOffsetHours
        return Date(timeIntervalSince1970: (jd - 2440587.5) * 86400 + utHours * 3600)
    }

    private static func clock(_ date: Date, utcOffsetHours: Double) -> String {
        let local = date.addingTimeInterval(utcOffsetHours * 3600)
        let secondsOfDay = Int(local.timeIntervalSince1970.rounded()) % 86400
        let positive = secondsOfDay < 0 ? secondsOfDay + 86400 : secondsOfDay
        return String(format: "%02d:%02d", positive / 3600, (positive % 3600) / 60)
    }
}
