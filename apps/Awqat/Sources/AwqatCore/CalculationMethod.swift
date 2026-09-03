import Foundation

/// How Isha is defined by a given convention.
public enum IshaRule: Sendable, Equatable {
    /// Sun is `angle` degrees below the horizon.
    case angle(Double)
    /// A fixed interval after Maghrib, in minutes. Used by Umm al-Qura and Qatar.
    case intervalAfterMaghrib(Int)
}

/// Which juristic position sets the Asr shadow length.
public enum AsrSchool: Sendable, Equatable, CaseIterable {
    /// Shafi'i, Maliki, Hanbali. Shadow equal to object height.
    case standard
    /// Hanafi. Shadow twice the object height.
    case hanafi

    public var shadowFactor: Double {
        switch self {
        case .standard: return 1
        case .hanafi: return 2
        }
    }
}

/// What to do at latitudes where the sun never gets far enough below the horizon
/// for Fajr or Isha to have an astronomical solution.
public enum HighLatitudeRule: Sendable, Equatable, CaseIterable {
    /// Fajr and Isha are placed at the midpoint of the night.
    case middleOfTheNight
    /// Night is split in sevenths: Fajr one seventh before sunrise, Isha one
    /// seventh after sunset.
    case seventhOfTheNight
    /// The night portion is proportional to the convention's twilight angle.
    case twilightAngle

    /// Nothing here is a matter of astronomy — these are conventions adopted where
    /// astronomy gives no answer. The app must let the user pick, and must not
    /// pretend one is "the" correct value.
    public var displayName: String {
        switch self {
        case .middleOfTheNight: return "Middle of the night"
        case .seventhOfTheNight: return "One seventh of the night"
        case .twilightAngle: return "Twilight angle"
        }
    }
}

/// Per-prayer manual offsets in minutes, for matching a specific local mosque's
/// published timetable. Every real timetable differs from pure calculation by a
/// minute or two, and users overwhelmingly want to match their mosque.
public struct PrayerAdjustments: Sendable, Equatable {
    public var fajr: Int
    public var sunrise: Int
    public var dhuhr: Int
    public var asr: Int
    public var maghrib: Int
    public var isha: Int

    public init(fajr: Int = 0, sunrise: Int = 0, dhuhr: Int = 0, asr: Int = 0, maghrib: Int = 0, isha: Int = 0) {
        self.fajr = fajr
        self.sunrise = sunrise
        self.dhuhr = dhuhr
        self.asr = asr
        self.maghrib = maghrib
        self.isha = isha
    }

    public static let none = PrayerAdjustments()
}

/// A named convention for computing prayer times.
///
/// The angles are the published values of each authority. They are data, not
/// opinion, and are kept in one place so a disagreement about a timetable can be
/// traced to a single number.
public struct CalculationParameters: Sendable, Equatable {
    public var fajrAngle: Double
    public var ishaRule: IshaRule
    /// Extra depression for Maghrib beyond sunset. Non-zero only for conventions
    /// that define Maghrib by an angle rather than by sunset.
    public var maghribAngle: Double
    public var asrSchool: AsrSchool
    public var highLatitudeRule: HighLatitudeRule
    public var adjustments: PrayerAdjustments
    /// Minutes added to solar transit to get Dhuhr.
    ///
    /// Zero by default: Dhuhr is solar noon, which is what the reference
    /// implementations and the published timetables compute. Mosques that print a
    /// small cushion past the zenith are handled through `adjustments`, so the
    /// astronomy stays separate from local practice.
    public var dhuhrOffsetMinutes: Int

    public init(
        fajrAngle: Double,
        ishaRule: IshaRule,
        maghribAngle: Double = 0,
        asrSchool: AsrSchool = .standard,
        highLatitudeRule: HighLatitudeRule = .middleOfTheNight,
        adjustments: PrayerAdjustments = .none,
        dhuhrOffsetMinutes: Int = 0
    ) {
        self.fajrAngle = fajrAngle
        self.ishaRule = ishaRule
        self.maghribAngle = maghribAngle
        self.asrSchool = asrSchool
        self.highLatitudeRule = highLatitudeRule
        self.adjustments = adjustments
        self.dhuhrOffsetMinutes = dhuhrOffsetMinutes
    }
}

public enum CalculationMethod: String, Sendable, CaseIterable, Identifiable {
    case muslimWorldLeague
    case egyptian
    case karachi
    case ummAlQura
    case dubai
    case northAmerica
    case kuwait
    case qatar
    case singapore
    case turkey
    case tehran

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .muslimWorldLeague: return "Muslim World League"
        case .egyptian: return "Egyptian General Authority"
        case .karachi: return "University of Islamic Sciences, Karachi"
        case .ummAlQura: return "Umm al-Qura, Makkah"
        case .dubai: return "Dubai"
        case .northAmerica: return "ISNA (North America)"
        case .kuwait: return "Kuwait"
        case .qatar: return "Qatar"
        case .singapore: return "Singapore (MUIS)"
        case .turkey: return "Diyanet (Turkey)"
        case .tehran: return "Institute of Geophysics, Tehran"
        }
    }

    public var parameters: CalculationParameters {
        switch self {
        case .muslimWorldLeague:
            return CalculationParameters(fajrAngle: 18, ishaRule: .angle(17))
        case .egyptian:
            return CalculationParameters(fajrAngle: 19.5, ishaRule: .angle(17.5))
        case .karachi:
            return CalculationParameters(fajrAngle: 18, ishaRule: .angle(18))
        case .ummAlQura:
            return CalculationParameters(fajrAngle: 18.5, ishaRule: .intervalAfterMaghrib(90))
        case .dubai:
            return CalculationParameters(
                fajrAngle: 18.2,
                ishaRule: .angle(18.2),
                adjustments: PrayerAdjustments(sunrise: -3, dhuhr: 3, asr: 3, maghrib: 3)
            )
        case .northAmerica:
            return CalculationParameters(fajrAngle: 15, ishaRule: .angle(15))
        case .kuwait:
            return CalculationParameters(fajrAngle: 18, ishaRule: .angle(17.5))
        case .qatar:
            return CalculationParameters(fajrAngle: 18, ishaRule: .intervalAfterMaghrib(90))
        case .singapore:
            return CalculationParameters(fajrAngle: 20, ishaRule: .angle(18))
        case .turkey:
            return CalculationParameters(
                fajrAngle: 18,
                ishaRule: .angle(17),
                adjustments: PrayerAdjustments(sunrise: -7, dhuhr: 5, asr: 4, maghrib: 7, isha: 2)
            )
        case .tehran:
            return CalculationParameters(
                fajrAngle: 17.7,
                ishaRule: .angle(14),
                maghribAngle: 4.5,
                highLatitudeRule: .middleOfTheNight
            )
        }
    }
}
