import XCTest
@testable import AwqatCore

final class PrayerLogicTests: XCTestCase {

    private let cairo = Coordinates(latitude: 30.0444, longitude: 31.2357)
    private let today = CalendarDate(year: 2026, month: 9, day: 3)

    private func times(
        _ method: CalculationMethod = .muslimWorldLeague,
        at coordinates: Coordinates? = nil,
        on date: CalendarDate? = nil
    ) throws -> PrayerTimes {
        try XCTUnwrap(
            PrayerTimes(
                coordinates: coordinates ?? cairo,
                date: date ?? today,
                method: method
            )
        )
    }

    func testTimesAreStrictlyIncreasing() throws {
        // Sampled across the year and across latitudes rather than one happy path,
        // because an ordering bug shows up seasonally.
        let places = [
            Coordinates(latitude: 30.0444, longitude: 31.2357),
            Coordinates(latitude: 51.5074, longitude: -0.1278),
            Coordinates(latitude: -33.8688, longitude: 151.2093),
            Coordinates(latitude: 1.3521, longitude: 103.8198),
            Coordinates(latitude: 55.7558, longitude: 37.6173)
        ]
        for place in places {
            for month in 1...12 {
                for method in CalculationMethod.allCases {
                    guard let times = PrayerTimes(
                        coordinates: place,
                        date: CalendarDate(year: 2026, month: month, day: 15),
                        method: method
                    ) else { continue }
                    let ordered = times.ordered
                    for i in 1..<ordered.count {
                        XCTAssertLessThan(
                            ordered[i - 1].time,
                            ordered[i].time,
                            "\(method.rawValue) at \(place.latitude) month \(month): "
                                + "\(ordered[i - 1].prayer.displayName) not before \(ordered[i].prayer.displayName)"
                        )
                    }
                }
            }
        }
    }

    func testMaghribEqualsSunsetWhenTheMethodHasNoMaghribAngle() throws {
        let times = try times(.muslimWorldLeague)
        XCTAssertEqual(times.maghrib, times.sunset)
    }

    func testTehranDepressesMaghribBelowSunset() throws {
        let times = try times(.tehran, at: Coordinates(latitude: 35.6892, longitude: 51.3890))
        XCTAssertGreaterThan(times.maghrib, times.sunset)
    }

    func testHanafiAsrIsLaterThanStandard() throws {
        var hanafi = CalculationMethod.muslimWorldLeague.parameters
        hanafi.asrSchool = .hanafi
        let standardTimes = try times(.muslimWorldLeague)
        let hanafiTimes = try XCTUnwrap(
            PrayerTimes(coordinates: cairo, date: today, method: .muslimWorldLeague, parameterOverride: hanafi)
        )
        XCTAssertGreaterThan(hanafiTimes.asr, standardTimes.asr)
        XCTAssertEqual(hanafiTimes.fajr, standardTimes.fajr, "Asr school must not move other prayers")
        XCTAssertEqual(hanafiTimes.isha, standardTimes.isha)
    }

    func testWiderFajrAngleMeansEarlierFajr() throws {
        // Egyptian uses 19.5°, ISNA 15°. A deeper angle happens earlier.
        let egyptian = try times(.egyptian)
        let isna = try times(.northAmerica)
        XCTAssertLessThan(egyptian.fajr, isna.fajr)
        XCTAssertGreaterThan(egyptian.isha, isna.isha)
    }

    func testManualAdjustmentsShiftOnlyTheirOwnPrayer() throws {
        var adjusted = CalculationMethod.muslimWorldLeague.parameters
        adjusted.adjustments = PrayerAdjustments(fajr: -5, isha: 7)
        let base = try times(.muslimWorldLeague)
        let shifted = try XCTUnwrap(
            PrayerTimes(coordinates: cairo, date: today, method: .muslimWorldLeague, parameterOverride: adjusted)
        )
        XCTAssertEqual(shifted.fajr.timeIntervalSince(base.fajr), -300, accuracy: 1)
        XCTAssertEqual(shifted.isha.timeIntervalSince(base.isha), 420, accuracy: 1)
        XCTAssertEqual(shifted.dhuhr, base.dhuhr)
        XCTAssertEqual(shifted.asr, base.asr)
    }

    func testEveryTimeLandsOnAWholeMinute() throws {
        let times = try times()
        for (prayer, time) in times.ordered {
            let seconds = time.timeIntervalSince1970
            XCTAssertEqual(
                seconds.truncatingRemainder(dividingBy: 60),
                0,
                accuracy: 1e-6,
                "\(prayer.displayName) is not on a whole minute"
            )
        }
    }

    // MARK: - The "what do I show on the watch face" logic

    func testNextReturnsTheFollowingEntry() throws {
        let times = try times()
        let justBeforeAsr = times.asr.addingTimeInterval(-1)
        let next = try XCTUnwrap(times.next(after: justBeforeAsr))
        XCTAssertEqual(next.prayer, .asr)
    }

    func testNextIsNilAfterIsha() throws {
        let times = try times()
        XCTAssertNil(times.next(after: times.isha.addingTimeInterval(1)))
    }

    func testCurrentIsNilBeforeFajr() throws {
        let times = try times()
        XCTAssertNil(times.current(at: times.fajr.addingTimeInterval(-1)))
        XCTAssertEqual(times.current(at: times.fajr), .fajr)
    }

    func testCurrentTracksTheWindow() throws {
        let times = try times()
        XCTAssertEqual(times.current(at: times.dhuhr.addingTimeInterval(60)), .dhuhr)
        XCTAssertEqual(times.current(at: times.asr.addingTimeInterval(-60)), .dhuhr)
        XCTAssertEqual(times.current(at: times.isha.addingTimeInterval(3600)), .isha)
    }

    func testSunriseIsNotTreatedAsAPrayer() {
        XCTAssertFalse(Prayer.sunrise.isObligatoryPrayer)
        XCTAssertEqual(Prayer.allCases.filter(\.isObligatoryPrayer).count, 5)
    }

    // MARK: - Polar behaviour

    /// The engine must decline to answer rather than invent times where the sun does
    /// not cross the horizon. An app that silently shows a made-up Fajr in Svalbard
    /// is worse than one that says it cannot compute.
    func testReturnsNilInsidePolarNight() {
        let svalbard = Coordinates(latitude: 78.2232, longitude: 15.6469)
        XCTAssertNil(
            PrayerTimes(
                coordinates: svalbard,
                date: CalendarDate(year: 2026, month: 12, day: 21),
                method: .muslimWorldLeague
            )
        )
    }

    func testHighLatitudeRulesProduceOrderedTimesWhereAnglesFail() throws {
        // Reykjavik in late May: the 18° depression has no solution.
        let reykjavik = Coordinates(latitude: 64.1466, longitude: -21.9426)
        let date = CalendarDate(year: 2026, month: 5, day: 25)
        for rule in HighLatitudeRule.allCases {
            var parameters = CalculationMethod.muslimWorldLeague.parameters
            parameters.highLatitudeRule = rule
            let times = try XCTUnwrap(
                PrayerTimes(coordinates: reykjavik, date: date, method: .muslimWorldLeague, parameterOverride: parameters),
                "\(rule) produced no times"
            )
            XCTAssertLessThan(times.fajr, times.sunrise, "\(rule)")
            XCTAssertGreaterThan(times.isha, times.maghrib, "\(rule)")
        }
    }

    func testSeventhOfNightGivesALaterFajrThanMiddleOfNight() throws {
        let reykjavik = Coordinates(latitude: 64.1466, longitude: -21.9426)
        let date = CalendarDate(year: 2026, month: 5, day: 25)

        var middle = CalculationMethod.muslimWorldLeague.parameters
        middle.highLatitudeRule = .middleOfTheNight
        var seventh = CalculationMethod.muslimWorldLeague.parameters
        seventh.highLatitudeRule = .seventhOfTheNight

        let middleTimes = try XCTUnwrap(
            PrayerTimes(coordinates: reykjavik, date: date, method: .muslimWorldLeague, parameterOverride: middle)
        )
        let seventhTimes = try XCTUnwrap(
            PrayerTimes(coordinates: reykjavik, date: date, method: .muslimWorldLeague, parameterOverride: seventh)
        )
        // A seventh of the night is a smaller slice than half, so Fajr is later.
        XCTAssertGreaterThan(seventhTimes.fajr, middleTimes.fajr)
        XCTAssertLessThan(seventhTimes.isha, middleTimes.isha)
    }

    // MARK: - Qibla

    func testQiblaMatchesPublishedBearings() {
        // Independently checked against api.aladhan.com/v1/qibla on 2026-09-03.
        let cases: [(name: String, coordinates: Coordinates, bearing: Double)] = [
            ("London", Coordinates(latitude: 51.5074, longitude: -0.1278), 118.98724251452296),
            ("New York", Coordinates(latitude: 40.7128, longitude: -74.0060), 58.481712034206865),
            ("Sydney", Coordinates(latitude: -33.8688, longitude: 151.2093), 277.499589412883)
        ]
        for testCase in cases {
            let qibla = Qibla(from: testCase.coordinates)
            XCTAssertEqual(qibla.bearing, testCase.bearing, accuracy: 0.01, testCase.name)
        }
    }

    func testQiblaIsAlwaysAValidBearing() {
        for latitude in stride(from: -80.0, through: 80.0, by: 10.0) {
            for longitude in stride(from: -180.0, through: 180.0, by: 15.0) {
                let bearing = Qibla(from: Coordinates(latitude: latitude, longitude: longitude)).bearing
                XCTAssertTrue(bearing >= 0 && bearing < 360, "\(latitude),\(longitude) -> \(bearing)")
                XCTAssertFalse(bearing.isNaN)
            }
        }
    }

    func testQiblaDueNorthFromDirectlySouthOfMakkah() {
        let southOfKaaba = Coordinates(latitude: -10, longitude: Qibla.kaaba.longitude)
        XCTAssertEqual(Qibla(from: southOfKaaba).bearing, 0, accuracy: 1e-6)
    }

    func testQiblaDueSouthFromDirectlyNorthOfMakkah() {
        let northOfKaaba = Coordinates(latitude: 50, longitude: Qibla.kaaba.longitude)
        XCTAssertEqual(Qibla(from: northOfKaaba).bearing, 180, accuracy: 1e-6)
    }

    func testDistanceToKaaba() {
        // Makkah to itself.
        XCTAssertEqual(Qibla.distanceKilometres(from: Qibla.kaaba), 0, accuracy: 1e-6)
        // London to Makkah is about 4,800 km.
        let london = Coordinates(latitude: 51.5074, longitude: -0.1278)
        XCTAssertEqual(Qibla.distanceKilometres(from: london), 4800, accuracy: 100)
    }
}
