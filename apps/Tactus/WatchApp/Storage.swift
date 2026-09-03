import Foundation

/// A saved tempo, for a setlist.
///
/// Musicians do not practise at one tempo; they work through a set. Saving a name
/// with a tempo and meter is the difference between a metronome you use once and
/// one you keep on your wrist for a gig.
struct Preset: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var bpm: Double
    var beatsPerBar: Int
    var beatUnit: Int
    var subdivision: Int
    var accentedBeats: [Int]

    var settings: MetronomeSettings {
        MetronomeSettings(
            bpm: bpm,
            timeSignature: TimeSignature(beatsPerBar: beatsPerBar, beatUnit: beatUnit),
            subdivision: subdivision,
            accentedBeats: Set(accentedBeats)
        )
    }

    init(name: String, settings: MetronomeSettings) {
        self.name = name
        self.bpm = settings.bpm
        self.beatsPerBar = settings.timeSignature.beatsPerBar
        self.beatUnit = settings.timeSignature.beatUnit
        self.subdivision = settings.subdivision
        self.accentedBeats = settings.accentedBeats.sorted()
    }
}

/// `UserDefaults` rather than SwiftData or a database.
///
/// The whole persisted state is a tempo, a meter and a handful of named presets.
/// A store that needs a schema migration for that is a liability on a device where
/// a slow launch is the difference between using the app and giving up on it.
enum Storage {
    private enum Key {
        static let bpm = "settings.bpm"
        static let beatsPerBar = "settings.beatsPerBar"
        static let beatUnit = "settings.beatUnit"
        static let subdivision = "settings.subdivision"
        static let accents = "settings.accentedBeats"
        static let hapticProfile = "settings.hapticProfile"
        static let audioClick = "settings.audioClickEnabled"
        static let presets = "presets"
    }

    // `UserDefaults` is thread-safe but is not annotated `Sendable`, so a
    // static reference to it is rejected under strict concurrency. The
    // annotation records that the safety is real and comes from the framework,
    // rather than silencing an actual race.
    private nonisolated(unsafe) static let defaults = UserDefaults.standard

    static var settings: MetronomeSettings? {
        get {
            let bpm = defaults.double(forKey: Key.bpm)
            guard bpm > 0 else { return nil }
            let beatsPerBar = defaults.integer(forKey: Key.beatsPerBar)
            let beatUnit = defaults.integer(forKey: Key.beatUnit)
            let subdivision = defaults.integer(forKey: Key.subdivision)
            let accents = defaults.array(forKey: Key.accents) as? [Int] ?? []
            return MetronomeSettings(
                bpm: bpm,
                timeSignature: TimeSignature(
                    beatsPerBar: max(1, beatsPerBar),
                    beatUnit: max(1, beatUnit)
                ),
                subdivision: max(1, subdivision),
                accentedBeats: Set(accents)
            )
        }
        set {
            guard let newValue else { return }
            defaults.set(newValue.bpm, forKey: Key.bpm)
            defaults.set(newValue.timeSignature.beatsPerBar, forKey: Key.beatsPerBar)
            defaults.set(newValue.timeSignature.beatUnit, forKey: Key.beatUnit)
            defaults.set(newValue.subdivision, forKey: Key.subdivision)
            defaults.set(newValue.accentedBeats.sorted(), forKey: Key.accents)
        }
    }

    static var hapticProfile: HapticProfile {
        get {
            guard let raw = defaults.string(forKey: Key.hapticProfile),
                  let profile = HapticProfile(rawValue: raw) else { return .firm }
            return profile
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hapticProfile) }
    }

    static var audioClickEnabled: Bool {
        get { defaults.bool(forKey: Key.audioClick) }
        set { defaults.set(newValue, forKey: Key.audioClick) }
    }

    static var presets: [Preset] {
        get {
            guard let data = defaults.data(forKey: Key.presets),
                  let decoded = try? JSONDecoder().decode([Preset].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.presets)
        }
    }
}
