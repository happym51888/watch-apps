import Foundation

/// Everything the user can change, in one Codable value.
///
/// Kept as a single struct written to `UserDefaults` as JSON rather than as a
/// scatter of individual keys, because prayer settings are meaningful only as a
/// set: a method implies angles, which interact with the high-latitude rule,
/// which interacts with the manual adjustments. Reading them individually
/// invites half-applied states after an update.
struct Settings: Codable, Equatable, Sendable {

    var method: CalculationMethod = .muslimWorldLeague
    var asrSchool: AsrSchool = .standard
    var highLatitudeRule: HighLatitudeRule = .middleOfTheNight

    /// Per-prayer offsets in minutes. Almost every user eventually wants these:
    /// mosques publish rounded or cushioned times, and an app that cannot match
    /// the board on the wall is an app they stop trusting.
    var adjustmentFajr = 0
    var adjustmentSunrise = 0
    var adjustmentDhuhr = 0
    var adjustmentAsr = 0
    var adjustmentMaghrib = 0
    var adjustmentIsha = 0

    /// Which prayers raise a notification.
    var notify: Set<String> = Set(
        Prayer.allCases.filter(\.isObligatoryPrayer).map(\.rawValue)
    )

    /// Fajr gets a real alarm rather than a notification. See `AlarmScheduler`
    /// for why this is the one that needs different treatment.
    var fajrAlarmEnabled = false
    /// Minutes before Fajr to fire the alarm, for suhoor.
    var fajrAlarmLeadMinutes = 0

    /// Last known position, so the app has something to show before Core
    /// Location answers — and something to fall back on when it never does.
    var lastLatitude: Double?
    var lastLongitude: Double?
    var lastPlaceName: String?
    var lastLocationFix: Date?

    var tasbihCount = 0
    var tasbihTarget = 33

    var coordinates: Coordinates? {
        guard let lastLatitude, let lastLongitude else { return nil }
        return Coordinates(latitude: lastLatitude, longitude: lastLongitude)
    }

    var adjustments: PrayerAdjustments {
        PrayerAdjustments(
            fajr: adjustmentFajr,
            sunrise: adjustmentSunrise,
            dhuhr: adjustmentDhuhr,
            asr: adjustmentAsr,
            maghrib: adjustmentMaghrib,
            isha: adjustmentIsha
        )
    }

    /// The method's published parameters with the user's choices layered on.
    ///
    /// Asr school and the high-latitude rule are user settings rather than
    /// method properties on purpose: a Hanafi user in Britain follows Karachi's
    /// angles but their own madhab's Asr, and no published method encodes that
    /// combination.
    var parameters: CalculationParameters {
        var parameters = method.parameters
        parameters.asrSchool = asrSchool
        parameters.highLatitudeRule = highLatitudeRule

        // Method-supplied adjustments (Dubai, Turkey) are the convention's own
        // corrections, so the user's offsets add to them rather than replace.
        let base = parameters.adjustments
        parameters.adjustments = PrayerAdjustments(
            fajr: base.fajr + adjustmentFajr,
            sunrise: base.sunrise + adjustmentSunrise,
            dhuhr: base.dhuhr + adjustmentDhuhr,
            asr: base.asr + adjustmentAsr,
            maghrib: base.maghrib + adjustmentMaghrib,
            isha: base.isha + adjustmentIsha
        )
        return parameters
    }
}

// MARK: - Persistence

enum SettingsStore {
    private static let key = "awqat.settings.v1"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            return Settings()
        }
        return decoded
    }

    static func save(_ settings: Settings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Codable conformance for the core enums

// These live in AwqatCore, which has no Codable dependency by design — the
// calculation engine should not know how a UI persists anything. Conformance is
// added here instead, keyed on the raw values, which are stable.

extension CalculationMethod: Codable {}

extension AsrSchool: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "hanafi" ? .hanafi : .standard
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .hanafi ? "hanafi" : "standard")
    }
}

extension HighLatitudeRule: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "seventh": .seventhOfTheNight
        case "twilight": .twilightAngle
        default: .middleOfTheNight
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Bound to a local first: a `switch` expression is only allowed as the
        // source of an assignment, a return, or a throw — not inline as a call
        // argument.
        let token = switch self {
        case .middleOfTheNight: "middle"
        case .seventhOfTheNight: "seventh"
        case .twilightAngle: "twilight"
        }
        try container.encode(token)
    }
}
