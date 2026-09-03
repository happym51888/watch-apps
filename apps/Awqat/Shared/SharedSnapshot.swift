import Foundation

/// The handoff between the app and the complication.
///
/// The complication runs in its own process. It could recompute the timetable —
/// the engine is pure arithmetic and would happily run there — but it would need
/// its own location permission, and any disagreement between the two processes
/// would show up as a watch face that contradicts the app. Neither is worth it
/// for one line of text.
///
/// So the app writes a two-field snapshot whenever anything changes, and the
/// complication only ever reads. This file is compiled into both targets; it is
/// the only code they share.
enum SharedSnapshot {

    /// Must match the App Group in both targets' entitlements.
    static let suiteName = "group.app.awqat"
    private static let key = "awqat.next"

    struct Payload: Codable, Equatable {
        let prayerName: String
        let time: Date
        let placeName: String?
    }

    static func write(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
    }

    static func read() -> Payload? {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
