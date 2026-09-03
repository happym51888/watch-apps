import XCTest
@testable import AwqatCore

final class AstronomyTests: XCTestCase {

    // MARK: - Julian day, against worked examples in Meeus chapter 7

    func testJulianDayMatchesMeeusExamples() {
        // Meeus 7.a: 1957 October 4.5 -> 2436116.5 at 0h, the Sputnik launch date.
        XCTAssertEqual(julianDay(year: 1957, month: 10, day: 4), 2436116.5, accuracy: 1e-9)
        // J2000.0 epoch: 2000 January 1.5 = JD 2451545.0, so 0h is 2451544.5.
        XCTAssertEqual(julianDay(year: 2000, month: 1, day: 1), 2451544.5, accuracy: 1e-9)
        // The Unix epoch.
        XCTAssertEqual(julianDay(year: 1970, month: 1, day: 1), 2440587.5, accuracy: 1e-9)
        // A January date exercises the m <= 2 branch.
        XCTAssertEqual(julianDay(year: 2026, month: 2, day: 28), 2461469.5, accuracy: 1e-9)
    }

    func testJulianDaysAreConsecutive() {
        var previous = julianDay(year: 2025, month: 12, day: 30)
        for (month, day) in [(12, 31), (1, 1), (1, 2)] {
            let year = month == 12 ? 2025 : 2026
            let current = julianDay(year: year, month: month, day: day)
            XCTAssertEqual(current - previous, 1.0, accuracy: 1e-9, "\(year)-\(month)-\(day)")
            previous = current
        }
    }

    // MARK: - Solar position

    /// Declination swings between roughly ±23.44° and hits zero at the equinoxes.
    func testDeclinationAtSolsticesAndEquinoxes() {
        let summer = SolarPosition.at(julianDay: julianDay(year: 2026, month: 6, day: 21) + 0.5)
        XCTAssertEqual(summer.declination, 23.44, accuracy: 0.05)

        let winter = SolarPosition.at(julianDay: julianDay(year: 2026, month: 12, day: 21) + 0.5)
        XCTAssertEqual(winter.declination, -23.44, accuracy: 0.05)

        let marchEquinox = SolarPosition.at(julianDay: julianDay(year: 2026, month: 3, day: 20) + 0.5)
        XCTAssertEqual(marchEquinox.declination, 0, accuracy: 0.4)

        let septemberEquinox = SolarPosition.at(julianDay: julianDay(year: 2026, month: 9, day: 23) + 0.5)
        XCTAssertEqual(septemberEquinox.declination, 0, accuracy: 0.4)
    }

    func testDeclinationStaysInsideObliquity() {
        var jd = julianDay(year: 2026, month: 1, day: 1)
        for _ in 0..<365 {
            let declination = SolarPosition.at(julianDay: jd).declination
            XCTAssertLessThanOrEqual(abs(declination), 23.5)
            jd += 1
        }
    }

    /// The equation of time has a well-known shape: about -14 minutes in mid
    /// February, +16 in early November, and four zero crossings a year.
    func testEquationOfTimeExtremesAndZeroCrossings() {
        let february = SolarPosition.at(julianDay: julianDay(year: 2026, month: 2, day: 11) + 0.5)
        XCTAssertEqual(february.equationOfTime, -14.2, accuracy: 0.7)

        let november = SolarPosition.at(julianDay: julianDay(year: 2026, month: 11, day: 3) + 0.5)
        XCTAssertEqual(november.equationOfTime, 16.4, accuracy: 0.7)

        var crossings = 0
        var previous = SolarPosition.at(julianDay: julianDay(year: 2026, month: 1, day: 1)).equationOfTime
        var jd = julianDay(year: 2026, month: 1, day: 2)
        for _ in 0..<364 {
            let current = SolarPosition.at(julianDay: jd).equationOfTime
            if (previous < 0) != (current < 0) { crossings += 1 }
            previous = current
            jd += 1
        }
        XCTAssertEqual(crossings, 4)
    }

    // MARK: - Hour angle and daily geometry

    func testSunNeverRisesInsidePolarNight() {
        // Longyearbyen, Svalbard, in the middle of December.
        let day = SolarDay(year: 2026, month: 12, day: 21, latitude: 78.2232, longitude: 15.6469)
        XCTAssertNil(day.sunrise)
        XCTAssertNil(day.sunset)
    }

    func testSunNeverSetsInsideMidnightSun() {
        let day = SolarDay(year: 2026, month: 6, day: 21, latitude: 78.2232, longitude: 15.6469)
        XCTAssertNil(day.sunrise)
        XCTAssertNil(day.sunset)
    }

    func testEquinoxDayIsAboutTwelveHoursEverywhere() throws {
        for latitude in [-60.0, -30.0, 0.0, 30.0, 60.0] {
            let day = SolarDay(year: 2026, month: 3, day: 20, latitude: latitude, longitude: 0)
            let sunrise = try XCTUnwrap(day.sunrise, "no sunrise at \(latitude)")
            let sunset = try XCTUnwrap(day.sunset, "no sunset at \(latitude)")
            // Refraction makes the apparent day slightly longer than 12 hours, and
            // more so towards the poles.
            XCTAssertEqual(sunset - sunrise, 12.0, accuracy: 0.5, "latitude \(latitude)")
        }
    }

    func testSunriseAndSunsetStraddleSolarNoon() throws {
        let day = SolarDay(year: 2026, month: 9, day: 3, latitude: 35.6895, longitude: 139.6917)
        let sunrise = try XCTUnwrap(day.sunrise)
        let sunset = try XCTUnwrap(day.sunset)
        XCTAssertLessThan(sunrise, day.transit)
        XCTAssertGreaterThan(sunset, day.transit)
        // Symmetric about noon to within the change in declination across the day.
        XCTAssertEqual(day.transit - sunrise, sunset - day.transit, accuracy: 0.02)
    }

    func testHigherElevationMovesSunriseEarlier() throws {
        let sea = SolarDay(year: 2026, month: 9, day: 3, latitude: 27.9881, longitude: 86.9250, elevation: 0)
        let summit = SolarDay(year: 2026, month: 9, day: 3, latitude: 27.9881, longitude: 86.9250, elevation: 8849)
        let seaSunrise = try XCTUnwrap(sea.sunrise)
        let summitSunrise = try XCTUnwrap(summit.sunrise)
        XCTAssertLessThan(summitSunrise, seaSunrise)
        // Roughly 3.26° of horizon depression at the top of Everest.
        XCTAssertEqual(summit.horizonAltitude, -0.833 - 0.0347 * sqrt(8849), accuracy: 1e-9)
    }

    func testLongerShadowMeansLaterAsr() throws {
        let day = SolarDay(year: 2026, month: 9, day: 3, latitude: 30.0444, longitude: 31.2357)
        let standard = try XCTUnwrap(day.asrTime(shadowFactor: 1))
        let hanafi = try XCTUnwrap(day.asrTime(shadowFactor: 2))
        XCTAssertGreaterThan(hanafi, standard)
        // Hanafi Asr sits between the standard Asr and sunset.
        XCTAssertLessThan(hanafi, try XCTUnwrap(day.sunset))
    }

    /// Asr is defined by shadow length, so the strongest available check is to take
    /// the time the solver returns, work out the sun's altitude there, and back out
    /// the shadow factor it implies. It has to come back to the factor asked for.
    ///
    /// Worth asserting because it is exactly where the reference implementation
    /// drifts: AlAdhan's published standard-school Asr times imply a factor of
    /// 0.98-0.99 rather than 1.0, which is why this engine reads up to a minute
    /// later than theirs. The definition is the thing to be faithful to.
    func testAsrTimeSatisfiesTheShadowDefinition() throws {
        let places: [(Double, Double)] = [
            (51.5074, -0.1278), (40.7128, -74.0060), (-6.2088, 106.8456),
            (-33.8688, 151.2093), (30.0444, 31.2357), (21.4225, 39.8262)
        ]
        for (latitude, longitude) in places {
            for month in [1, 4, 7, 10] {
                for factor in [1.0, 2.0] {
                    let day = SolarDay(
                        year: 2026, month: month, day: 15,
                        latitude: latitude, longitude: longitude
                    )
                    let asr = try XCTUnwrap(day.asrTime(shadowFactor: factor))
                    let position = SolarPosition.at(julianDay: day.julianDayAtMidnightUT + asr / 24.0)

                    // Sun altitude at the returned time, from the hour angle.
                    let hourAngle = radians((asr - day.transit) * 15)
                    let latRad = radians(latitude)
                    let decRad = radians(position.declination)
                    let sinAltitude = sin(latRad) * sin(decRad)
                        + cos(latRad) * cos(decRad) * cos(hourAngle)
                    let altitude = degrees(asin(sinAltitude))

                    let shadowRatio = 1 / tan(radians(altitude))
                    let noonZenith = abs(latitude - position.declination)
                    let implied = shadowRatio - tan(radians(noonZenith))

                    XCTAssertEqual(
                        implied, factor, accuracy: 0.001,
                        "lat \(latitude) month \(month) factor \(factor)"
                    )
                }
            }
        }
    }

    func testHanafiShadowPutsTheSunLower() {
        let day = SolarDay(year: 2026, month: 9, day: 3, latitude: 30.0444, longitude: 31.2357)
        let declination = SolarPosition.at(julianDay: day.julianDayAtMidnightUT + day.transit / 24).declination
        XCTAssertLessThan(
            day.asrAltitude(shadowFactor: 2, declination: declination),
            day.asrAltitude(shadowFactor: 1, declination: declination)
        )
    }

    func testAngleNormalisation() {
        XCTAssertEqual(normalizeDegrees(370), 10, accuracy: 1e-9)
        XCTAssertEqual(normalizeDegrees(-10), 350, accuracy: 1e-9)
        XCTAssertEqual(normalizeDegrees(0), 0, accuracy: 1e-9)
        XCTAssertEqual(normalizeHours(25), 1, accuracy: 1e-9)
        XCTAssertEqual(normalizeHours(-1), 23, accuracy: 1e-9)
    }
}
