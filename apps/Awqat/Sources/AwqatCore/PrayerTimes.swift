import Foundation

public enum Prayer: String, Sendable, CaseIterable, Identifiable {
    case fajr, sunrise, dhuhr, asr, maghrib, isha

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fajr: return "Fajr"
        case .sunrise: return "Sunrise"
        case .dhuhr: return "Dhuhr"
        case .asr: return "Asr"
        case .maghrib: return "Maghrib"
        case .isha: return "Isha"
        }
    }

    /// Sunrise is shown in the timetable but is not one of the five prayers.
    public var isObligatoryPrayer: Bool { self != .sunrise }
}

public struct Coordinates: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Metres above sea level. Only affects sunrise and sunset.
    public let elevation: Double

    public init(latitude: Double, longitude: Double, elevation: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
    }
}

/// A calendar day, kept as plain integers so the calculation never depends on the
/// device calendar or time zone.
public struct CalendarDate: Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = parts.year ?? 1970
        self.month = parts.month ?? 1
        self.day = parts.day ?? 1
    }
}

/// The six times for one day at one place, as absolute instants.
///
/// Instants rather than clock strings: the watch app, the complication and the
/// notification scheduler all need to compare against `Date()`, and formatting is
/// the presentation layer's job.
public struct PrayerTimes: Sendable {
    public let date: CalendarDate
    public let coordinates: Coordinates
    public let method: CalculationMethod

    public let fajr: Date
    public let sunrise: Date
    public let dhuhr: Date
    public let asr: Date
    public let maghrib: Date
    public let isha: Date

    /// Returns nil in the polar case, where the sun does not cross the horizon at
    /// all on this day and sunrise/sunset are undefined. Callers should surface
    /// that honestly rather than invent a time.
    public init?(
        coordinates: Coordinates,
        date: CalendarDate,
        method: CalculationMethod,
        parameterOverride: CalculationParameters? = nil
    ) {
        let parameters = parameterOverride ?? method.parameters
        let solar = SolarDay(
            year: date.year,
            month: date.month,
            day: date.day,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            elevation: coordinates.elevation
        )

        guard let sunriseUT = solar.sunrise, let sunsetUT = solar.sunset else { return nil }

        let transitUT = solar.transit

        // Asr: shadow-length definition, always solvable outside the polar case
        // because the required altitude is above the horizon by construction.
        let asrUT = solar.asrTime(shadowFactor: parameters.asrSchool.shadowFactor)
            ?? (transitUT + (sunsetUT - transitUT) * 0.7)

        // Maghrib is sunset unless the convention depresses it further.
        let maghribUT: Double
        if parameters.maghribAngle > 0 {
            maghribUT = solar.time(atAltitude: -parameters.maghribAngle, direction: .afterTransit) ?? sunsetUT
        } else {
            maghribUT = sunsetUT
        }

        // Night, used by every high-latitude fallback. Measured sunset to next
        // sunrise, which is the standard approximation.
        let night = (sunriseUT + 24) - sunsetUT

        let fajrUT = Self.resolveFajr(
            solar: solar,
            parameters: parameters,
            sunriseUT: sunriseUT,
            night: night
        )

        let ishaUT = Self.resolveIsha(
            solar: solar,
            parameters: parameters,
            sunsetUT: sunsetUT,
            maghribUT: maghribUT,
            night: night
        )

        let base = solar.julianDayAtMidnightUT
        let adjust = parameters.adjustments

        self.date = date
        self.coordinates = coordinates
        self.method = method
        self.fajr = Self.instant(base, fajrUT, plusMinutes: adjust.fajr)
        self.sunrise = Self.instant(base, sunriseUT, plusMinutes: adjust.sunrise)
        self.dhuhr = Self.instant(base, transitUT, plusMinutes: parameters.dhuhrOffsetMinutes + adjust.dhuhr)
        self.asr = Self.instant(base, asrUT, plusMinutes: adjust.asr)
        self.maghrib = Self.instant(base, maghribUT, plusMinutes: adjust.maghrib)
        self.isha = Self.instant(base, ishaUT, plusMinutes: adjust.isha)
    }

    public func time(for prayer: Prayer) -> Date {
        switch prayer {
        case .fajr: return fajr
        case .sunrise: return sunrise
        case .dhuhr: return dhuhr
        case .asr: return asr
        case .maghrib: return maghrib
        case .isha: return isha
        }
    }

    /// Times in chronological order.
    public var ordered: [(prayer: Prayer, time: Date)] {
        Prayer.allCases.map { ($0, time(for: $0)) }
    }

    /// The prayer whose window contains `instant`, or nil when `instant` is before
    /// this day's Fajr.
    public func current(at instant: Date) -> Prayer? {
        ordered.last { $0.time <= instant }?.prayer
    }

    /// The next entry after `instant` within this day, or nil once Isha has passed.
    public func next(after instant: Date) -> (prayer: Prayer, time: Date)? {
        ordered.first { $0.time > instant }
    }

    // MARK: - Fajr and Isha, including the high-latitude fallbacks

    private static func resolveFajr(
        solar: SolarDay,
        parameters: CalculationParameters,
        sunriseUT: Double,
        night: Double
    ) -> Double {
        let limit = sunriseUT - nightPortion(
            angle: parameters.fajrAngle,
            rule: parameters.highLatitudeRule,
            night: night
        )
        guard let computed = solar.time(atAltitude: -parameters.fajrAngle, direction: .beforeTransit) else {
            return limit
        }
        // The angle has a solution but it falls absurdly early, or before the
        // convention's floor. Take the floor.
        return max(computed, limit)
    }

    private static func resolveIsha(
        solar: SolarDay,
        parameters: CalculationParameters,
        sunsetUT: Double,
        maghribUT: Double,
        night: Double
    ) -> Double {
        switch parameters.ishaRule {
        case .intervalAfterMaghrib(let minutes):
            return maghribUT + Double(minutes) / 60.0
        case .angle(let angle):
            let limit = sunsetUT + nightPortion(
                angle: angle,
                rule: parameters.highLatitudeRule,
                night: night
            )
            guard let computed = solar.time(atAltitude: -angle, direction: .afterTransit) else {
                return limit
            }
            return min(computed, limit)
        }
    }

    /// How much of the night the fallback rule assigns to twilight.
    private static func nightPortion(angle: Double, rule: HighLatitudeRule, night: Double) -> Double {
        switch rule {
        case .middleOfTheNight:
            return night / 2
        case .seventhOfTheNight:
            return night / 7
        case .twilightAngle:
            return night * angle / 60
        }
    }

    /// Julian Day at 00:00 UT plus a UT hour offset, as a `Date`.
    ///
    /// Goes straight from Julian Day to Unix epoch — 2440587.5 is the Julian Day of
    /// 1970-01-01T00:00:00Z — so no `Calendar` or `TimeZone` is involved and there
    /// is no daylight-saving edge case to get wrong.
    private static func instant(_ julianDayAtMidnightUT: Double, _ utHours: Double, plusMinutes minutes: Int) -> Date {
        let jd = julianDayAtMidnightUT + utHours / 24.0
        let unix = (jd - 2440587.5) * 86400.0 + Double(minutes) * 60.0
        // Prayer timetables are published to the minute. Rounding to the minute
        // keeps the app's display, its notifications and its complication from
        // ever disagreeing by a second.
        return Date(timeIntervalSince1970: (unix / 60.0).rounded() * 60.0)
    }
}
