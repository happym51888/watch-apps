import SwiftUI

/// What is on the watch and where it has got to.
///
/// This screen exists because the alternative is a user who does not know
/// whether their recording survived. Every state a recording can be in is
/// nameable here, in words, including the bad ones.
struct QueueView: View {
    @Environment(DeliveryCoordinator.self) private var delivery

    var body: some View {
        List {
            if delivery.queue.items.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(delivery.queue.items.reversed()) { item in
                QueueRow(item: item)
                    .swipeActions(edge: .trailing) {
                        if item.state == .blocked || item.state == .pending {
                            Button {
                                delivery.retry(item.id)
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                    }
            }

            if delivery.queue.undeliveredCount > 0 {
                Button {
                    delivery.retryAll()
                } label: {
                    Label("Send all now", systemImage: "arrow.up.circle")
                        .font(.caption2)
                }
            }

            Section {
                Text(footerExplanation)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footerExplanation: String {
        """
        Audio is deleted from the watch only after your iPhone confirms it \
        received it. If the watch runs out of space, recording keeps working \
        and nothing waiting to send is ever removed.
        """
    }
}

private struct QueueRow: View {
    let item: Recording

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? item.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var symbol: String {
        switch item.state {
        case .pending: item.nextAttemptAt == nil ? "clock" : "clock.badge.exclamationmark"
        case .inFlight: "arrow.up.circle"
        case .delivered: item.hasLocalFile ? "checkmark.circle.fill" : "checkmark.circle"
        case .blocked: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.state {
        case .pending: .secondary
        case .inFlight: .blue
        case .delivered: .green
        case .blocked: .orange
        }
    }

    /// Plain language, no jargon. "Waiting for iPhone" is a state a person can
    /// act on; "pending (attempt 3)" is not.
    private var detail: String {
        let length = duration
        switch item.state {
        case .pending:
            return item.attempts == 0
                ? "\(length) · waiting for iPhone"
                : "\(length) · will try again"
        case .inFlight:
            return "\(length) · sending"
        case .delivered:
            return item.hasLocalFile
                ? "\(length) · on your iPhone"
                : "\(length) · on your iPhone, freed here"
        case .blocked:
            return "\(length) · \(item.blockReason ?? "couldn't send") Swipe to retry."
        }
    }

    private var duration: String {
        let total = Int(item.duration.rounded())
        return total >= 60
            ? String(format: "%d:%02d", total / 60, total % 60)
            : "\(total)s"
    }
}
