import SwiftUI
import VerbaCore

@main
struct VerbaApp: App {
    @State private var recorder = Recorder()
    @State private var delivery = DeliveryCoordinator()

    var body: some Scene {
        WindowGroup {
            RecordView()
                .environment(recorder)
                .environment(delivery)
                .onAppear {
                    delivery.start()
                    // The recorder hands finished audio straight to the queue.
                    // Wiring it here, rather than inside the recorder, keeps
                    // capture and delivery independent of each other.
                    recorder.onFinished = { recording, _ in
                        delivery.enqueue(recording)
                    }
                }
        }
    }
}

/// One tap to record. That is the whole app.
///
/// The button is enormous and centred because the realistic use is pressing it
/// without looking, or while walking, or mid-conversation. There is no
/// confirmation step, no naming prompt, no folder picker — every one of those
/// is a reason the thought is gone before the recording starts.
struct RecordView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(DeliveryCoordinator.self) private var delivery

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                switch recorder.state {
                case .denied:
                    PermissionNeeded()
                case .failed(let reason):
                    FailureNotice(reason: reason)
                default:
                    recordButton
                    statusLine
                }
            }
            .padding(.horizontal, 4)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        QueueView()
                    } label: {
                        BacklogBadge(count: delivery.queue.undeliveredCount)
                    }
                }
            }
        }
    }

    // MARK: - Button

    private var recordButton: some View {
        Button {
            recorder.isRecording ? recorder.stop() : recorder.start()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.red.opacity(0.85))
                    .frame(width: 96, height: 96)

                // The ring pulses with input level, which is the only honest
                // way to show "it is hearing you" without a waveform that
                // costs a redraw every frame.
                if recorder.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 4)
                        .frame(width: 96 + CGFloat(recorder.level) * 26,
                               height: 96 + CGFloat(recorder.level) * 26)
                        .animation(.easeOut(duration: 0.15), value: recorder.level)
                }

                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        if case .recording(let since) = recorder.state {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(since: since, now: context.date))
                    .font(.system(.title3, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
            Text("Lower your wrist — it keeps recording")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        } else if let pressure = delivery.storagePressure {
            Label(
                "Storage full — \(pressure.used / 1_048_576) MB waiting to send",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.system(size: 9))
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
        } else if delivery.queue.undeliveredCount > 0 {
            Label(
                "\(delivery.queue.undeliveredCount) waiting for your iPhone",
                systemImage: delivery.isPhoneReachable ? "arrow.up.circle" : "iphone.slash"
            )
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        } else {
            Text("Tap to record")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func elapsed(since: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(since)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Badge

private struct BacklogBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "list.bullet")
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(count > 0 ? .orange : .secondary)
    }
}

// MARK: - States

private struct PermissionNeeded: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "mic.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Microphone is off")
                    .font(.headline)
                Text("Verba can't record without it. Turn it on in the Watch app on your iPhone, under Privacy.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct FailureNotice: View {
    let reason: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                Text("Nothing already recorded was lost.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
