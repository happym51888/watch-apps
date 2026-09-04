import Foundation
import XCTest
@testable import ProximaCore

/// The board itself: calendars, exceptions, times past midnight, and the
/// selection rules that decide whether a row is a departure at all.
///
/// The feeds here are hand-built, small enough to check on paper, and shaped
/// around the same hazards `validation/verify_gtfs.py` exercises against a real
/// Oslo feed and Entur's own journey planner.
final class DepartureBoardTests: XCTestCase {

    // MARK: - A small feed

    /// One stop, one route, one weekday service, three departures.
    private func feed(
        stopTimes: String,
        calendar: String = """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            weekday,1,1,1,1,1,0,0,20260101,20261231
            """,
        calendarDates: String = "",
        trips: String = """
            trip_id,route_id,service_id,trip_headsign
            t1,r1,weekday,Downtown
            """,
        stops: String = """
            stop_id,stop_name,parent_station,location_type
            s1,First Street,,0
            s2,Second Street,,0
            """,
        feedInfo: String = "",
        select: [String] = ["s1"]
    ) throws -> Timetable {
        try SliceCompiler.compile(
            FeedTexts(
                agency: """
                    agency_name,agency_timezone
                    Test Transit,America/Los_Angeles
                    """,
                stops: stops,
                routes: """
                    route_id,route_short_name,route_long_name,route_type
                    r1,7,Seventh Avenue Line,3
                    """,
                trips: trips,
                stopTimes: stopTimes,
                calendar: calendar,
                calendarDates: calendarDates,
                feedInfo: feedInfo
            ),
            stopIDs: select
        )
    }

    private func instant(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        zone: String = "America/Los_Angeles"
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    // MARK: - The basics

    func testDeparturesComeBackInOrderAndBoundedByTheLimit() throws {
        let table = try feed(stopTimes: """
            trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
            t1,s1,1,08:00:00,08:00:00,0
            t1,s2,2,08:10:00,08:10:00,0
            """)

        let board = nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 6, 15, 7, 0))
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board[0].routeLabel, "7")
        XCTAssertEqual(board[0].headsign, "Downtown")
        XCTAssertEqual(board[0].minutesAway(from: instant(2026, 6, 15, 7, 0)), 60)
    }

    func testMinutesAwayRoundsDown() throws {
        let table = try feed(stopTimes: """
            trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
            t1,s1,1,08:00:00,08:00:00,0
            t1,s2,2,08:10:00,08:10:00,0
            """)
        let now = instant(2026, 6, 15, 7, 58).addingTimeInterval(31)   // 89 s to go
        let board = nextDepartures(table, stopIDs: ["s1"], now: now)
        // Telling a rider "2 min" when the bus leaves in 89 seconds is how
        // they miss it. Round down, always.
        XCTAssertEqual(board[0].minutesAway(from: now), 1)
    }

    func testAServiceThatDoesNotRunTodayIsNotOnTheBoard() throws {
        let table = try feed(stopTimes: """
            trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
            t1,s1,1,08:00:00,08:00:00,0
            t1,s2,2,08:10:00,08:10:00,0
            """)
        // 2026-06-13 is a Saturday and the service is weekdays only.
        XCTAssertTrue(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 6, 13, 7, 0)).isEmpty)
    }

    // MARK: - H2 and H7, past midnight

    func testALateNightTripBelongsToTheDayItStartedOn() throws {
        let table = try feed(stopTimes: """
            trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
            t1,s1,1,25:30:00,25:30:00,0
            t1,s2,2,25:40:00,25:40:00,0
            """)

        // Standing at the stop at 01:00 on Tuesday. The only departure is
        // Monday's 25:30, which is 01:30 Tuesday. A board that looks at today
        // only shows nothing at all, which reads as "no more trains" at
        // precisely the hour when the answer matters most.
        let board = nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 6, 16, 1, 0))
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board[0].serviceDay, ServiceDate(year: 2026, month: 6, day: 15))
        XCTAssertEqual(board[0].minutesAway(from: instant(2026, 6, 16, 1, 0)), 30)
    }

    func testATripBeyondTheLookbackIsRefusedAtCompileTimeRatherThanMisplaced() {
        // The resolver scans two service days back, so it can place anything up
        // to 72:00:00. Past that a trip would be resolved against the wrong
        // day, silently, which is far worse than refusing the slice.
        XCTAssertNoThrow(
            try feed(stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,49:00:00,49:00:00,0
                t1,s2,2,49:10:00,49:10:00,0
                """)
        )
        XCTAssertThrowsError(
            try feed(stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,73:00:00,73:00:00,0
                t1,s2,2,73:10:00,73:10:00,0
                """)
        )
    }

    // MARK: - H1, the clocks changing

    func testAPublishedTimeStillMeansThatTimeOnADayTheClocksChange() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,08:00:00,08:00:00,0
                t1,s2,2,08:10:00,08:10:00,0
                """,
            calendar: """
                service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
                everyday,1,1,1,1,1,1,1,20260101,20261231
                """,
            trips: """
                trip_id,route_id,service_id,trip_headsign
                t1,r1,everyday,Downtown
                """
        )

        // 2026-03-08 is the spring-forward Sunday in Los Angeles: a 23-hour
        // day. This is what the noon-minus-twelve rule is *for* — the agency
        // published 08:00 and the bus leaves at 08:00, on a day when eight
        // elapsed hours after midnight would be nine o'clock.
        let board = nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 3, 8, 5, 0))
        XCTAssertEqual(board.count, 1)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = table.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: board[0].when)
        XCTAssertEqual(parts.hour, 8, "a 08:00:00 trip still departs at 08:00 local")
        XCTAssertEqual(parts.minute, 0)

        // Spelled out, because "it happens to be right" and "it is right for a
        // reason" are hard to tell apart from a passing assertion. Anchoring
        // the service day at midnight instead puts the same trip an hour late,
        // and this is the arithmetic that would do it.
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let naive = midnight.addingTimeInterval(8 * 3_600)
        XCTAssertEqual(
            calendar.dateComponents([.hour], from: naive).hour,
            9,
            "the midnight rule would announce this bus an hour after it left"
        )
        XCTAssertEqual(naive.timeIntervalSince(board[0].when), 3_600, accuracy: 0.5)

        // And on an ordinary day the two agree, which is exactly why the wrong
        // rule survives testing.
        let ordinaryMidnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        let ordinary = nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 3, 9, 5, 0))
        XCTAssertEqual(calendar.dateComponents([.hour], from: ordinary[0].when).hour, 8)
        XCTAssertEqual(
            ordinaryMidnight.addingTimeInterval(8 * 3_600).timeIntervalSince(ordinary[0].when),
            0,
            accuracy: 0.5
        )
    }

    // MARK: - H3, exceptions

    func testAnExceptionCancelsAServiceTheCalendarSaysIsRunning() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,08:00:00,08:00:00,0
                t1,s2,2,08:10:00,08:10:00,0
                """,
            calendarDates: """
                service_id,date,exception_type
                weekday,20260703,2
                """
        )

        // 2026-07-03 is a Friday the calendar covers, removed by an exception.
        // An engine that only unions the additions runs a full timetable on a
        // public holiday.
        XCTAssertTrue(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 7, 3, 6, 0)).isEmpty)
        XCTAssertFalse(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 7, 2, 6, 0)).isEmpty)
    }

    func testAnExceptionAddsAServiceOnADayTheCalendarExcludes() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,08:00:00,08:00:00,0
                t1,s2,2,08:10:00,08:10:00,0
                """,
            calendarDates: """
                service_id,date,exception_type
                weekday,20260704,1
                """
        )
        // A Saturday, which the weekday calendar excludes.
        XCTAssertEqual(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 7, 4, 6, 0)).count, 1)
    }

    // MARK: - H4, inclusive bounds

    func testBothEndsOfACalendarWindowAreIncluded() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,08:00:00,08:00:00,0
                t1,s2,2,08:10:00,08:10:00,0
                """,
            calendar: """
                service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
                weekday,1,1,1,1,1,1,1,20260601,20260630
                """
        )
        // The last day of a timetable is a real service day. Writing the range
        // as half-open takes it off the board, and nobody notices until the
        // day the timetable rolls over.
        XCTAssertFalse(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 6, 1, 6, 0)).isEmpty)
        XCTAssertFalse(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 6, 30, 6, 0)).isEmpty)
        XCTAssertTrue(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 7, 1, 6, 0)).isEmpty)
    }

    // MARK: - H5 and H6, what counts as a departure

    func testAStopTheVehiclePassesWithoutBoardingIsNotADeparture() throws {
        let table = try feed(stopTimes: """
            trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
            t1,s1,1,08:00:00,08:00:00,1
            t1,s2,2,08:10:00,08:10:00,0
            """)
        // Showing it tells the rider to stand at a stop where the doors will
        // not open.
        XCTAssertTrue(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 6, 15, 6, 0)).isEmpty)
    }

    func testTheLastStopOfATripIsAnArrivalAndNotADeparture() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s2,1,07:50:00,07:50:00,0
                t1,s1,2,08:00:00,08:00:00,0
                """,
            select: ["s1"]
        )
        // s1 is the terminus. GTFS still gives it a departure_time, and most
        // feeds also mark it pickup_type 1 鈥?but not all, and a board that
        // relies on that shows a train "leaving" a station it terminates at.
        XCTAssertTrue(nextDepartures(table, stopIDs: ["s1"], now: instant(2026, 6, 15, 6, 0)).isEmpty)
    }

    // MARK: - H8, blank times

    func testBlankTimesAreInterpolatedRatherThanDroppedOrZeroed() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s2,1,08:00:00,08:00:00,0
                t1,s1,2,,,0
                t1,s3,3,08:40:00,08:40:00,0
                """,
            stops: """
                stop_id,stop_name,parent_station,location_type
                s1,First Street,,0
                s2,Second Street,,0
                s3,Third Street,,0
                """,
            select: ["s1"]
        )

        let now = instant(2026, 6, 15, 6, 0)
        let board = nextDepartures(table, stopIDs: ["s1"], now: now)
        XCTAssertEqual(board.count, 1, "a blank time must not take the stop off the board")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = table.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: board[0].when)
        // Halfway between 08:00 and 08:40. Treating the blank as zero would
        // put this at midnight instead.
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 20)
    }

    // MARK: - H9, an expired slice

    func testValidityIsDerivedFromTheCalendarsAndNotFromFeedInfo() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,08:00:00,08:00:00,0
                t1,s2,2,08:10:00,08:10:00,0
                """,
            feedInfo: """
                feed_publisher_name,feed_start_date,feed_end_date
                Test Transit,20260101,20260630
                """
        )

        // feed_info claims the feed ends in June; calendar.txt runs to
        // December. The BART feed used while building this had exactly that
        // disagreement, and believing feed_info would have blanked the board
        // for four months of perfectly good timetable.
        XCTAssertEqual(table.validity(on: ServiceDate(year: 2026, month: 9, day: 4)), .current)
        XCTAssertEqual(table.validity(on: ServiceDate(year: 2027, month: 1, day: 4)), .expired)
        XCTAssertEqual(table.validity(on: ServiceDate(year: 2025, month: 1, day: 4)), .future)
        XCTAssertTrue(table.declarationDisagrees)
    }

    // MARK: - H10, stations and platforms

    func testAskingAboutAStationAsksAboutItsPlatforms() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,q1,1,08:00:00,08:00:00,0
                t1,q2,2,08:10:00,08:10:00,0
                """,
            stops: """
                stop_id,stop_name,parent_station,location_type
                big,Big Station,,1
                q1,Big Station platform 1,big,0
                q2,Big Station platform 2,big,0
                """,
            select: ["big"]
        )

        // No trip calls at the station record itself; they call at its quays.
        // A board that queries the saved id verbatim finds nothing and shows
        // an empty screen that looks like a service outage.
        XCTAssertEqual(table.expand(["big"]).sorted(), ["big", "q1", "q2"])
        XCTAssertEqual(nextDepartures(table, stopIDs: ["big"], now: instant(2026, 6, 15, 6, 0)).count, 1)
    }

    // MARK: - Properties

    func testTheBoardIsSortedDeduplicatedAndInsideTheHorizon() throws {
        var rows = ["trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type"]
        var trips = ["trip_id,route_id,service_id,trip_headsign"]
        for hour in 5..<23 {
            rows.append("t\(hour),s1,1,\(String(format: "%02d", hour)):15:00,\(String(format: "%02d", hour)):15:00,0")
            rows.append("t\(hour),s2,2,\(String(format: "%02d", hour)):25:00,\(String(format: "%02d", hour)):25:00,0")
            trips.append("t\(hour),r1,weekday,Downtown")
        }
        let table = try feed(
            stopTimes: rows.joined(separator: "\n"),
            trips: trips.joined(separator: "\n")
        )

        let now = instant(2026, 6, 15, 6, 0)
        let board = nextDepartures(table, stopIDs: ["s1"], now: now, limit: 6, horizon: 4 * 3_600)

        XCTAssertEqual(board.count, 4, "the horizon bounds the answer, not just the limit")
        XCTAssertEqual(board, board.sorted { $0.when < $1.when })
        XCTAssertEqual(Set(board.map(\.id)).count, board.count)
        for departure in board {
            XCTAssertGreaterThanOrEqual(departure.when, now)
            XCTAssertLessThanOrEqual(departure.when.timeIntervalSince(now), 4 * 3_600)
        }

        XCTAssertEqual(
            nextDepartures(table, stopIDs: ["s1"], now: now, limit: 3).count, 3
        )
    }

    func testAnUnknownStopReturnsNothingRatherThanEverything() throws {
        let table = try feed(stopTimes: """
            trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
            t1,s1,1,08:00:00,08:00:00,0
            t1,s2,2,08:10:00,08:10:00,0
            """)
        XCTAssertTrue(nextDepartures(table, stopIDs: ["nope"], now: instant(2026, 6, 15, 6, 0)).isEmpty)
        XCTAssertTrue(nextDepartures(table, stopIDs: [], now: instant(2026, 6, 15, 6, 0)).isEmpty)
    }

    // MARK: - Round trip

    func testASliceSurvivesBeingEncodedAndDecoded() throws {
        let table = try feed(stopTimes: """
            trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
            t1,s1,1,08:00:00,08:00:00,0
            t1,s2,2,08:10:00,08:10:00,0
            """)
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(Timetable.self, from: data)

        let now = instant(2026, 6, 15, 6, 0)
        XCTAssertEqual(
            nextDepartures(decoded, stopIDs: ["s1"], now: now).map(\.id),
            nextDepartures(table, stopIDs: ["s1"], now: now).map(\.id)
        )
        XCTAssertEqual(decoded.timeZoneID, table.timeZoneID)
    }

    func testExceptionsSurviveTheRoundTrip() throws {
        let table = try feed(
            stopTimes: """
                trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type
                t1,s1,1,08:00:00,08:00:00,0
                t1,s2,2,08:10:00,08:10:00,0
                """,
            calendarDates: """
                service_id,date,exception_type
                weekday,20260703,2
                """
        )
        let decoded = try JSONDecoder().decode(
            Timetable.self, from: JSONEncoder().encode(table)
        )
        // A cancellation that does not survive the transfer to the watch is
        // the same bug as never having read it.
        XCTAssertTrue(
            nextDepartures(decoded, stopIDs: ["s1"], now: instant(2026, 7, 3, 6, 0)).isEmpty
        )
    }

    // MARK: - Refusing an unusable feed

    func testAFeedWithoutAUsableTimezoneIsRefused() {
        XCTAssertThrowsError(
            try SliceCompiler.compile(
                FeedTexts(agency: "agency_name,agency_timezone\nT,Mars/Olympus"),
                stopIDs: ["s1"]
            )
        )
        XCTAssertThrowsError(
            try SliceCompiler.compile(FeedTexts(agency: ""), stopIDs: ["s1"])
        )
    }
}
