import SwiftUI
import WatchKit

/// Dhikr counter.
///
/// The whole screen is the button. Counting dhikr means eyes closed or elsewhere
/// and attention on the words, not on hitting a small target — so there is no
/// small target. The haptic is the confirmation, which is also what makes it
/// usable without looking at all.
///
/// The Digital Crown counts too, for people who prefer a physical detent and for
/// anyone wearing gloves.
struct TasbihView: View {
    @Environment(PrayerModel.self) private var model
    @State private var crownValue: Double = 0
    @State private var lastCrownStep = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Button {
                    tap()
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .focusable()
            .digitalCrownRotation(
                $crownValue,
                from: 0, through: 100_000, by: 1,
                sensitivity: .medium,
                isContinuous: true,
                isHapticFeedbackEnabled: false   // we play our own, on count only
            )
            .onChange(of: crownValue) { _, value in
                let step = Int(value)
                guard step != lastCrownStep else { return }
                // Only forward rotation counts. Spinning back is how people
                // undo an accidental nudge, not how they count.
                if step > lastCrownStep { tap() }
                lastCrownStep = step
            }
            .navigationTitle("Tasbih")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") { reset() }
                        .font(.caption2)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 2) {
            Text("\(model.settings.tasbihCount)")
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: model.settings.tasbihCount)

            if model.settings.tasbihTarget > 0 {
                let target = model.settings.tasbihTarget
                let inSet = model.settings.tasbihCount % target
                let completed = model.settings.tasbihCount / target

                Text(inSet == 0 && model.settings.tasbihCount > 0
                     ? "\(target) of \(target)"
                     : "\(inSet) of \(target)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if completed > 0 {
                    Text("\(completed) set\(completed == 1 ? "" : "s") complete")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("Tap anywhere, or turn the crown")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tap() {
        model.incrementTasbih()

        let target = model.settings.tasbihTarget
        // A distinct, stronger haptic on completing a set means you can count
        // to 33 three times over without opening your eyes once.
        if target > 0 && model.settings.tasbihCount % target == 0 {
            WKInterfaceDevice.current().play(.success)
        } else {
            WKInterfaceDevice.current().play(.click)
        }
    }

    private func reset() {
        model.resetTasbih()
        lastCrownStep = Int(crownValue)
        WKInterfaceDevice.current().play(.retry)
    }
}
