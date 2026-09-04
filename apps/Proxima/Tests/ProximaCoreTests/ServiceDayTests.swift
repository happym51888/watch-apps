import Foundation
import XCTest
@testable import ProximaCore

/// Service days, which are the reason this app has a core library at all.
///
/// A service day is not a day. It starts at noon minus twelve hours, it can be
/// 23 or 25 hours long, and it can run past midnight into the following date.
/// Every one of those facts is invisible on 361 days a year.
final class ServiceDayTests: XCTestCase {

    // MARK: - Civil arithmetic

    func testDaysSinceEpochRoundTripsAcrossCenturies() {
        // Includes 2000 (a leap year) and 2100 (not one), which is where a
        // hand-rolled leap rule goes wrong.
        for days in stride(from: -30_000, through: 60_000, by: 7) {
            let date = ServiceDate(daysSinceEpoch: days)
            XCTAssertEqual(date.daysSinceEpoch, days, "\(date)")
        }
    }

    func testKnownWeekdays() {
        // Monday is 0, matching the column order of calendar.txt. Getting this
        // off by one runs Sunday's timetable on Saturday.
        XCTAssertEqual(ServiceDate(year: 1970, month: 1, day: 1).weekdayIndex, 3)   // Thursday
        XCTAssertEqual(ServiceDate(year: 2026, month: 9, day: 4).weekdayIndex, 4)   // Friday
        XCTAssertEqual(ServiceDate(year: 2026, month: 3, day: 8).weekdayIndex, 6)   // Sunday
        XCTAssertEqual(ServiceDate(year: 2000, month: 2, day: 29).weekdayIndex, 1)  // Tuesday
        XCTAssertEqual(ServiceDate(year: 2100, month: 3, day: 1).weekdayIndex, 0)   // Monday
    }

    func testDateParsing() {
        XCTAssertEqual(ServiceDate(gtfs: "20260904"), ServiceDate(year: 2026, month: 9, day: 4))
        XCTAssertEqual(ServiceDate(gtfs: " 20260904 "), ServiceDate(year: 2026, month: 9, day: 4))
        XCTAssertNil(ServiceDate(gtfs: "2026-09-04"))
        XCTAssertNil(ServiceDate(gtfs: "202609"))
        XCTAssertNil(ServiceDate(gtfs: ""))
        XCTAssertNil(ServiceDate(gtfs: "20261304"))
    }

    // MARK: - Times past midnight

    func testTimesPastTwentyFourHoursSurviveParsing() throws {
        XCTAssertEqual(try GTFSTime.parse("00:00:00"), 0)
        XCTAssertEqual(try GTFSTime.parse("23:59:59"), 86_399)
        // The whole reason GTFS times are not clock times: this trip leaves at
        // half past one in the morning and belongs to the previous day's
        // service. Clamping it to 01:30 takes the last train off the board.
        XCTAssertEqual(try GTFSTime.parse("25:30:00"), 91_800)
        XCTAssertEqual(try GTFSTime.parse("47:59:00"), 172_740)
        XCTAssertNil(try GTFSTime.parse(""))
        XCTAssertNil(try GTFSTime.parse("   "))
    }

    func testMalformedTimesAreRefusedRatherThanDropped() {
        // A board that skips rows it cannot read is a board that silently
        // loses trains, which is worse than one that says it is broken.
        XCTAssertThrowsError(try GTFSTime.parse("12:00"))
        XCTAssertThrowsError(try GTFSTime.parse("12:60:00"))
        XCTAssertThrowsError(try GTFSTime.parse("12:00:60"))
        XCTAssertThrowsError(try GTFSTime.parse("-1:00:00"))
        XCTAssertThrowsError(try GTFSTime.parse("noon"))
    }

    // MARK: - The origin of a service day

    private func timetable(zone: String) -> Timetable {
        Timetable(
            agencyName: "T",
            timeZoneID: zone,
            stops: [:],
            routes: [:],
            trips: [:],
            calendars: [:],
            exceptions: [:],
            departuresByStop: [:]
        )
    }

    func testOnAnOrdinaryDayTheOriginIsMidnight() {
        let table = timetable(zone: "America/Los_Angeles")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = table.timeZone

        for day in [
            ServiceDate(year: 2026, month: 6, day: 15),
            ServiceDate(year: 2026, month: 12, day: 3)
        ] {
            let origin = table.serviceDayOrigin(day)
            let parts = calendar.dateComponents([.hour, .minute, .day], from: origin)
            XCTAssertEqual(parts.hour, 0, "\(day)")
            XCTAssertEqual(parts.minute, 0, "\(day)")
            XCTAssertEqual(parts.day, day.day, "\(day)")
        }
    }

    func testOnASpringForwardDayTheOriginIsAnHourBeforeMidnight() {
        // 2026-03-08, Los Angeles: the clocks go forward at 02:00, so the day
        // is 23 hours long. Noon minus twelve elapsed hours is 23:00 on the
        // 7th, an hour *earlier* than midnight on the 8th.
        //
        // A trip listed at 08:00:00 therefore departs at 07:00 local 鈥?which
        // is what the agency means and what the rider will experience. Using
        // midnight puts every departure on the board an hour late.
        let table = timetable(zone: "America/Los_Angeles")
        let day = ServiceDate(year: 2026, month: 3, day: 8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = table.timeZone
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!

        let origin = table.serviceDayOrigin(day)
        XCTAssertEqual(origin.timeIntervalSince(midnight), -3_600, accuracy: 0.5)
    }

    func testOnAFallBackDayTheOriginIsAnHourAfterMidnight() {
        // 2026-11-01, Los Angeles: 25-hour day, so noon minus twelve elapsed
        // hours lands at 01:00.
        let table = timetable(zone: "America/Los_Angeles")
        let day = ServiceDate(year: 2026, month: 11, day: 1)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = table.timeZone
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!

        let origin = table.serviceDayOrigin(day)
        XCTAssertEqual(origin.timeIntervalSince(midnight), 3_600, accuracy: 0.5)
    }

    func testEuropeanFallBackToo() {
        // Oslo changes on a different date from Los Angeles, and the fixture
        // this app was validated against is a Norwegian feed.
        let table = timetable(zone: "Europe/Oslo")
        let day = ServiceDate(year: 2026, month: 10, day: 25)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = table.timeZone
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))!

        XCTAssertEqual(
            table.serviceDayOrigin(day).timeIntervalSince(midnight),
            3_600,
            accuracy: 0.5
        )
    }

    func testTheSpanBetweenConsecutiveOriginsIsTheRealLengthOfTheDay() {
        let table = timetable(zone: "America/Los_Angeles")

        func span(_ from: ServiceDate, _ to: ServiceDate) -> TimeInterval {
            table.serviceDayOrigin(to).timeIntervalSince(table.serviceDayOrigin(from))
        }

        // Which pair of days is short is not the pair you first reach for. The
        // clocks move at 02:00 on 8 March, but both 7 and 8 March are anchored
        // at their own local noon — and noon on the 7th is still PST while noon
        // on the 8th is already PDT. So the missing hour shows up in the step
        // *into* the 8th, not the step out of it.
        XCTAssertEqual(span(.init(year: 2026, month: 3, day: 7),
                            .init(year: 2026, month: 3, day: 8)), 23 * 3_600, accuracy: 0.5)
        XCTAssertEqual(span(.init(year: 2026, month: 3, day: 8),
                            .init(year: 2026, month: 3, day: 9)), 24 * 3_600, accuracy: 0.5)

        // Same shape in the other direction: 1 November gains the hour, so the
        // long step is the one that lands on it.
        XCTAssertEqual(span(.init(year: 2026, month: 10, day: 31),
                            .init(year: 2026, month: 11, day: 1)), 25 * 3_600, accuracy: 0.5)
        XCTAssertEqual(span(.init(year: 2026, month: 11, day: 1),
                            .init(year: 2026, month: 11, day: 2)), 24 * 3_600, accuracy: 0.5)

        XCTAssertEqual(span(.init(year: 2026, month: 6, day: 15),
                            .init(year: 2026, month: 6, day: 16)), 24 * 3_600, accuracy: 0.5)
    }
}
