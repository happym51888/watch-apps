import SwiftUI

/// A setlist. Tap a tempo, it loads and starts.
///
/// Naming happens on the watch with dictation or the scribble keyboard, because
/// requiring an iPhone to name a preset would defeat the point of the app running
/// standalone.
struct PresetsView: View {
    @Environment(MetronomeEngine.self) private var engine
    @State private var presets: [Preset] = Storage.presets
    @State private var isNaming = false
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        draftName = defaultName
                        isNaming = true
                    } label: {
                        Label("Save \(Int(engine.settings.bpm)) bpm", systemImage: "plus.circle.fill")
                    }
                }

                if presets.isEmpty {
                    Section {
                        Text("Saved tempos appear here. Handy for working through a set without touching your phone.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Saved") {
                        ForEach(presets) { preset in
                            Button {
                                engine.apply(preset)
                                if !engine.isRunning { engine.start() }
                            } label: {
                                PresetRow(preset: preset)
                            }
                        }
                        .onDelete { offsets in
                            presets.remove(atOffsets: offsets)
                            Storage.presets = presets
                        }
                    }
                }
            }
            .navigationTitle("Setlist")
            .alert("Name", isPresented: $isNaming) {
                TextField("Name", text: $draftName)
                Button("Save") { save() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var defaultName: String {
        let signature = engine.settings.timeSignature
        return "\(Int(engine.settings.bpm)) · \(signature.beatsPerBar)/\(signature.beatUnit)"
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(
            name: name.isEmpty ? defaultName : name,
            settings: engine.settings
        )
        presets.append(preset)
        Storage.presets = presets
    }
}

struct PresetRow: View {
    let preset: Preset

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "play.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts = ["\(Int(preset.bpm)) bpm", "\(preset.beatsPerBar)/\(preset.beatUnit)"]
        if preset.subdivision > 1 { parts.append("÷\(preset.subdivision)") }
        return parts.joined(separator: " · ")
    }
}
