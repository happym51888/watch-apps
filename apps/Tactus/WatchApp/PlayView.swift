import SwiftUI

/// The only screen that matters. Everything on it is reachable without looking
/// twice: tempo on the crown, start/stop on a full-width tap target, and a bar
/// position you can read at a glance from a music stand.
struct PlayView: View {
    @Environment(MetronomeEngine.self) private var engine
    @State private var crownTempo: Double = 100
    @State private var tapTempo = TapTempo()
    @State private var isCrownFocused = true

    var body: some View {
        VStack(spacing: 4) {
            header
            tempoReadout
            BeatIndicator(
                beatsPerBar: engine.settings.timeSignature.beatsPerBar,
                currentBeat: engine.currentPulse?.beat,
                accentedBeats: engine.settings.accentedBeats,
                isRunning: engine.isRunning
            )
            controls
            footnote
        }
        .padding(.horizontal, 4)
        .focusable(true)
        .digitalCrownRotation(
            $crownTempo,
            from: MetronomeSettings.bpmRange.lowerBound,
            through: MetronomeSettings.bpmRange.upperBound,
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: false // the metronome owns the Taptic Engine
        )
        .onChange(of: crownTempo) { _, newValue in
            engine.setTempo(newValue.rounded())
        }
        .onAppear { crownTempo = engine.settings.bpm }
        .onChange(of: engine.settings.bpm) { _, newValue in
            // Keep the crown in step when a preset or tap tempo changes the tempo.
            if abs(crownTempo - newValue) > 0.5 { crownTempo = newValue }
        }
    }

    private var header: some View {
        HStack {
            Text(meterLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if engine.settings.subdivision > 1 {
                Text(subdivisionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tempoReadout: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text("\(Int(engine.settings.bpm))")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("bpm")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                engine.toggle()
            } label: {
                Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .accentColor)

            Button {
                registerTap()
            } label: {
                Text("TAP")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    /// Reserved space rather than a conditional row, so the controls never jump
    /// under the user's thumb when a message appears.
    private var footnote: some View {
        Text(footnoteText)
            .font(.system(size: 11))
            .foregroundStyle(footnoteColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(height: 26)
    }

    private var footnoteText: String {
        if let message = engine.interruptionMessage {
            return message
        }
        if tapTempo.tapCount == 1 {
            return "Keep tapping…"
        }
        if engine.plan.isThinned {
            return thinningExplanation
        }
        return ""
    }

    private var footnoteColor: Color {
        engine.interruptionMessage != nil ? .orange : .secondary
    }

    /// Says out loud what the rate limiter did. A user who feels taps on beats but
    /// not on the sixteenths they asked for should be told why, once, in plain
    /// words — otherwise it reads as the app being broken, which is exactly the
    /// review the existing watch metronomes get.
    private var thinningExplanation: String {
        switch engine.plan.coverage {
        case .everyPulse:
            return ""
        case .beatsOnly:
            return "Too fast to tap subdivisions — beats only"
        case .accentsOnly:
            return "Too fast to tap every beat — accents only"
        case .downbeatOnly:
            return "Too fast to tap every beat — downbeat only"
        case .everyNthBar(let n):
            return "Tapping every \(n) bars at this tempo"
        }
    }

    private var meterLabel: String {
        let signature = engine.settings.timeSignature
        return "\(signature.beatsPerBar)/\(signature.beatUnit)"
    }

    private var subdivisionLabel: String {
        switch engine.settings.subdivision {
        case 2: return "♪♪"
        case 3: return "triplets"
        case 4: return "16ths"
        default: return "×\(engine.settings.subdivision)"
        }
    }

    private func registerTap() {
        let now = Date.timeIntervalSinceReferenceDate
        if let bpm = tapTempo.tap(at: now) {
            engine.setTempo(bpm.rounded())
        }
    }
}

/// A dot per beat in the bar. Accented beats are drawn larger so an odd meter's
/// grouping (3+2+2 in 7/8, say) is visible rather than something you have to count.
struct BeatIndicator: View {
    let beatsPerBar: Int
    let currentBeat: Int?
    let accentedBeats: Set<Int>
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<beatsPerBar, id: \.self) { beat in
                Circle()
                    .fill(color(for: beat))
                    .frame(width: size(for: beat), height: size(for: beat))
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.05), value: currentBeat)
    }

    private func isActive(_ beat: Int) -> Bool {
        isRunning && currentBeat == beat
    }

    private func color(for beat: Int) -> Color {
        if isActive(beat) {
            return beat == 0 ? .orange : .accentColor
        }
        return .gray.opacity(0.35)
    }

    private func size(for beat: Int) -> CGFloat {
        let base: CGFloat = (beat == 0 || accentedBeats.contains(beat)) ? 10 : 7
        return isActive(beat) ? base + 3 : base
    }
}
