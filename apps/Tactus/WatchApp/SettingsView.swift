import SwiftUI

struct SettingsView: View {
    @Environment(MetronomeEngine.self) private var engine

    private static let meters: [TimeSignature] = [
        TimeSignature(beatsPerBar: 2, beatUnit: 4),
        TimeSignature(beatsPerBar: 3, beatUnit: 4),
        TimeSignature(beatsPerBar: 4, beatUnit: 4),
        TimeSignature(beatsPerBar: 5, beatUnit: 4),
        TimeSignature(beatsPerBar: 6, beatUnit: 8),
        TimeSignature(beatsPerBar: 7, beatUnit: 8),
        TimeSignature(beatsPerBar: 9, beatUnit: 8),
        TimeSignature(beatsPerBar: 12, beatUnit: 8)
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Meter") {
                    Picker("Time signature", selection: meterBinding) {
                        ForEach(Self.meters, id: \.self) { meter in
                            Text("\(meter.beatsPerBar)/\(meter.beatUnit)").tag(meter)
                        }
                    }

                    Picker("Subdivision", selection: subdivisionBinding) {
                        Text("Beats").tag(1)
                        Text("Eighths").tag(2)
                        Text("Triplets").tag(3)
                        Text("Sixteenths").tag(4)
                    }
                }

                Section("Accents") {
                    AccentPicker()
                }

                Section("Haptics") {
                    Picker("Strength", selection: profileBinding) {
                        ForEach(HapticProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    Text(engine.hapticProfile.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Audible click", isOn: audioBinding)
                    Text(
                        "Adds a click on the speaker or your headphones. "
                        + "Also lets the beat keep running with your wrist down, "
                        + "and carries subdivisions the wrist is too slow to tap."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Sound")
                }

                Section("Rate limit") {
                    Text(limitExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    /// The honest version of the constraint, in the settings rather than buried in
    /// a support page: the Taptic Engine has a floor of 100 ms between taps and
    /// needs more than that for a tap to read as a beat, so past roughly 176 bpm
    /// something has to give.
    private var limitExplanation: String {
        let gap = engine.plan.tightestGap
        let effective = gap > 0 ? Int((60.0 / gap).rounded()) : 0
        return """
        The watch can only tap so fast. Right now taps land \
        \(String(format: "%.2f", gap))s apart, about \(effective) a minute. \
        Past that Tactus drops subdivisions first, then unaccented beats, \
        rather than letting the pattern smear.
        """
    }

    // MARK: - Bindings

    private var meterBinding: Binding<TimeSignature> {
        Binding(
            get: { engine.settings.timeSignature },
            set: { newValue in
                var updated = engine.settings
                updated.timeSignature = newValue
                // Drop accents that no longer exist in the shorter bar.
                updated.accentedBeats = updated.accentedBeats.filter { $0 < newValue.beatsPerBar }
                engine.settings = updated
            }
        )
    }

    private var subdivisionBinding: Binding<Int> {
        Binding(
            get: { engine.settings.subdivision },
            set: { newValue in
                var updated = engine.settings
                updated.subdivision = newValue
                engine.settings = updated
            }
        )
    }

    private var profileBinding: Binding<HapticProfile> {
        Binding(
            get: { engine.hapticProfile },
            set: { engine.hapticProfile = $0 }
        )
    }

    private var audioBinding: Binding<Bool> {
        Binding(
            get: { engine.audioClickEnabled },
            set: { engine.audioClickEnabled = $0 }
        )
    }
}

/// Toggle any beat except the downbeat, which is always accented.
struct AccentPicker: View {
    @Environment(MetronomeEngine.self) private var engine

    var body: some View {
        let beatsPerBar = engine.settings.timeSignature.beatsPerBar
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<beatsPerBar, id: \.self) { beat in
                    Button {
                        toggle(beat)
                    } label: {
                        Text("\(beat + 1)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(tint(for: beat))
                    .disabled(beat == 0)
                }
            }
            Text("Beat 1 is always accented. Tap others to add an accent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func tint(for beat: Int) -> Color {
        if beat == 0 { return .orange }
        return engine.settings.accentedBeats.contains(beat) ? .accentColor : .gray
    }

    private func toggle(_ beat: Int) {
        guard beat != 0 else { return }
        var updated = engine.settings
        if updated.accentedBeats.contains(beat) {
            updated.accentedBeats.remove(beat)
        } else {
            updated.accentedBeats.insert(beat)
        }
        engine.settings = updated
    }
}
