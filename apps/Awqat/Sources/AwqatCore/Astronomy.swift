import Foundation

// Solar position maths behind the prayer times.
//
// Formulas follow Meeus, *Astronomical Algorithms*, 2nd ed., chapters 7 (Julian
// day), 25 (solar coordinates) and 28 (equation of time), at the "low accuracy"
// level Meeus gives as sufficient to ~0.01°. That is well inside the precision
// prayer timetables are published to, which is whole minutes.
//
// Everything here is pure arithmetic on Doubles: no Foundation date handling, no
// time zones, no platform APIs. That is deliberate — it is the part that has to be
// right, so it is the part that has to be testable anywhere.

@inline(__always) func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
@inline(__always) func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

/// Normalises an angle into `[0, 360)`.
@inline(__always) func normalizeDegrees(_ value: Double) -> Double {
    let wrapped = value.truncatingRemainder(dividingBy: 360)
    return wrapped < 0 ? wrapped + 360 : wrapped
}

/// Normalises an hour value into `[0, 24)`.
@inline(__always) func normalizeHours(_ value: Double) -> Double {
    let wrapped = value.truncatingRemainder(dividingBy: 24)
    return wrapped < 0 ? wrapped + 24 : wrapped
}

/// Julian Day for a Gregorian calendar date at 00:00 UT. Meeus 7.1.
public func julianDay(year: Int, month: Int, day: Int) -> Double {
    var y = year
    var m = month
    if m <= 2 {
        y -= 1
        m += 12
    }
    let a = (Double(y) / 100).rounded(.down)
    let b = 2 - a + (a / 4).rounded(.down)
    return (365.25 * (Double(y) + 4716)).rounded(.down)
        + (30.6001 * (Double(m) + 1)).rounded(.down)
        + Double(day) + b - 1524.5
}

/// The two solar quantities prayer times need.
public struct SolarPosition: Sendable, Equatable {
    /// Apparent declination of the sun, in degrees.
    public let declination: Double
    /// Equation of time, in minutes. Apparent solar time minus mean solar time.
    public let equationOfTime: Double

    public static func at(julianDay jd: Double) -> SolarPosition {
        // Julian centuries from J2000.0.
        let t = (jd - 2451545.0) / 36525.0

        // Geometric mean longitude of the sun. Meeus 25.2.
        let l0 = normalizeDegrees(280.46646 + 36000.76983 * t + 0.0003032 * t * t)
        // Mean anomaly of the sun. Meeus 25.3.
        let m = normalizeDegrees(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
        // Eccentricity of Earth's orbit. Meeus 25.4.
        let e = 0.016708634 - 0.000042037 * t - 0.0000001267 * t * t

        // Equation of the centre. Meeus p. 164.
        let mRad = radians(m)
        let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(mRad)
            + (0.019993 - 0.000101 * t) * sin(2 * mRad)
            + 0.000289 * sin(3 * mRad)

        let trueLongitude = l0 + c

        // Longitude of the ascending node of the Moon's mean orbit, used for the
        // nutation and aberration corrections. Meeus p. 165.
        let omega = 125.04 - 1934.136 * t
        let omegaRad = radians(omega)
        // Apparent longitude, corrected for nutation and aberration.
        let lambda = trueLongitude - 0.00569 - 0.00478 * sin(omegaRad)

        // Mean obliquity of the ecliptic. Meeus 22.2, in degrees.
        let epsilon0 = 23.439291
            - 0.0130042 * t
            - 1.64e-7 * t * t
            + 5.04e-7 * t * t * t
        // True obliquity, for use with the apparent longitude. Meeus p. 165.
        let epsilon = epsilon0 + 0.00256 * cos(omegaRad)

        let declination = degrees(asin(sin(radians(epsilon)) * sin(radians(lambda))))

        // Equation of time. Meeus 28.3.
        let y = pow(tan(radians(epsilon / 2)), 2)
        let l0Rad = radians(l0)
        let eotRadians = y * sin(2 * l0Rad)
            - 2 * e * sin(mRad)
            + 4 * e * y * sin(mRad) * cos(2 * l0Rad)
            - 0.5 * y * y * sin(4 * l0Rad)
            - 1.25 * e * e * sin(2 * mRad)
        // Meeus gives the result in radians of hour angle; 4 minutes per degree.
        let equationOfTime = 4 * degrees(eotRadians)

        return SolarPosition(declination: declination, equationOfTime: equationOfTime)
    }
}

/// Which side of solar noon an event falls on.
public enum SolarEventDirection: Sendable {
    case beforeTransit
    case afterTransit
}

/// Solar geometry for one calendar day at one place.
///
/// All returned values are hours in UT for that day, and may fall slightly outside
/// `[0, 24)` for places whose local day straddles the UT day boundary. The caller
/// converts to a wall-clock instant.
public struct SolarDay: Sendable {
    public let julianDayAtMidnightUT: Double
    public let latitude: Double
    public let longitude: Double
    /// Observer height above the horizon in metres, used to depress the horizon for
    /// sunrise and sunset. Ignored for the angle-based prayers, which are defined
    /// against the geometric horizon.
    public let elevation: Double

    public init(year: Int, month: Int, day: Int, latitude: Double, longitude: Double, elevation: Double = 0) {
        self.julianDayAtMidnightUT = julianDay(year: year, month: month, day: day)
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = max(0, elevation)
    }

    /// Solar noon in UT hours. Iterated because the equation of time is itself a
    /// function of the moment we are solving for.
    public var transit: Double {
        var noon = 12.0 - longitude / 15.0
        for _ in 0..<3 {
            let position = SolarPosition.at(julianDay: julianDayAtMidnightUT + noon / 24.0)
            noon = 12.0 - longitude / 15.0 - position.equationOfTime / 60.0
        }
        return noon
    }

    /// UT hour at which the sun's centre reaches `altitude` degrees above the
    /// horizon, or nil when it never does on this day at this latitude.
    public func time(atAltitude altitude: Double, direction: SolarEventDirection) -> Double? {
        var estimate = transit
        // Two passes: solve with the declination at solar noon, then re-solve with
        // the declination at the time we just found. A third pass moves the answer
        // by well under a second.
        for _ in 0..<2 {
            let position = SolarPosition.at(julianDay: julianDayAtMidnightUT + estimate / 24.0)
            guard let hourAngle = Self.hourAngle(
                altitude: altitude,
                latitude: latitude,
                declination: position.declination
            ) else {
                return nil
            }
            let offset = hourAngle / 15.0
            estimate = direction == .beforeTransit ? transit - offset : transit + offset
        }
        return estimate
    }

    /// Altitude of the sun's upper limb at apparent sunrise/sunset: half the solar
    /// diameter plus standard refraction, then depressed for observer elevation.
    public var horizonAltitude: Double {
        -0.833 - 0.0347 * sqrt(elevation)
    }

    public var sunrise: Double? { time(atAltitude: horizonAltitude, direction: .beforeTransit) }
    public var sunset: Double? { time(atAltitude: horizonAltitude, direction: .afterTransit) }

    /// Sun altitude for Asr, evaluated for a given declination.
    ///
    /// Asr begins when an object's shadow has grown by `shadowFactor` times the
    /// object's height beyond its length at noon. `shadowFactor` is 1 for the
    /// Shafi'i, Maliki and Hanbali positions and 2 for the Hanafi position.
    public func asrAltitude(shadowFactor: Double, declination: Double) -> Double {
        let noonZenith = abs(latitude - declination)
        return degrees(atan(1.0 / (shadowFactor + tan(radians(noonZenith)))))
    }

    /// UT hour of Asr.
    ///
    /// Unlike the other prayers, Asr's target altitude is itself a function of the
    /// declination, so both the altitude and the hour angle have to be iterated
    /// together. Evaluating the altitude once at solar noon instead leaves a
    /// systematic error of up to a minute against published timetables — small, but
    /// it is a bias rather than rounding noise, and it always pushes Asr late.
    public func asrTime(shadowFactor: Double) -> Double? {
        var estimate = transit
        for _ in 0..<3 {
            let position = SolarPosition.at(julianDay: julianDayAtMidnightUT + estimate / 24.0)
            let altitude = asrAltitude(shadowFactor: shadowFactor, declination: position.declination)
            guard let hourAngle = Self.hourAngle(
                altitude: altitude,
                latitude: latitude,
                declination: position.declination
            ) else {
                return nil
            }
            estimate = transit + hourAngle / 15.0
        }
        return estimate
    }

    /// Hour angle, in degrees, for a given sun altitude. Nil when the sun never
    /// reaches that altitude — the polar case.
    static func hourAngle(altitude: Double, latitude: Double, declination: Double) -> Double? {
        let latRad = radians(latitude)
        let decRad = radians(declination)
        let denominator = cos(latRad) * cos(decRad)
        guard abs(denominator) > 1e-12 else { return nil }
        let cosH = (sin(radians(altitude)) - sin(latRad) * sin(decRad)) / denominator
        guard cosH >= -1, cosH <= 1 else { return nil }
        return degrees(acos(cosH))
    }
}
