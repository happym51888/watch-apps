import SwiftUI
import AwqatCore

/// The main screen: what is next, then the whole day.
struct TimetableView: View {
    @Environment(PrayerModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    if model.settings.coordinates == nil {
                        NoLocationState(status: model.location.status)
                    } else {
                        nextPrayerHeader
                        if model.polarDay {
                            PolarDayNotice()
                        } else {
                            dayList
                        }
                        locationFooter
                    }
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle("Awqat")
        }
    }

    // MARK: - Header

    private var nextPrayerHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let next = model.upcoming(now: context.date) {
                VStack(spacing: 1) {
                    Text(next.prayer.displayName.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)

                    Text(next.time, style: .time)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                    // A countdown rather than only a clock time. "In 41 minutes"
                    // is the thing people actually want to know, and it is what
                    // a glance at a watch is for.
                    Text(remaining(until: next.time, from: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.bottom, 2)
            }
        }
    }

    private func remaining(until target: Date, from now: Date) -> String {
        let seconds = Int(target.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in under a minute"
    }

    // MARK: - The day

    @ViewBuilder
    private var dayList: some View {
        if let times = model.times {
            let now = Date()
            let current = times.current(at: now)

            VStack(spacing: 0) {
                ForEach(times.ordered, id: \.prayer.id) { entry in
                    PrayerRow(
                        prayer: entry.prayer,
                        time: entry.time,
                        isCurrent: entry.prayer == current,
                        isPast: entry.time <= now
                    )
                }
            }
        }
    }

    // MARK: - Footer

    private var locationFooter: some View {
        VStack(spacing: 1) {
            Text(model.settings.lastPlaceName ?? coordinateText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(model.settings.method.displayName)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            // Staleness is stated rather than hidden. If the times are computed
            // from a fix taken in another city, the user needs to know that
            // before they trust them.
            if let fix = model.settings.lastLocationFix,
               Date().timeIntervalSince(fix) > 12 * 3600 {
                Label(
                    "Location last updated \(fix.formatted(.relative(presentation: .named)))",
                    systemImage: "location.slash"
                )
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 4)
    }

    private var coordinateText: String {
        guard let coordinates = model.settings.coordinates else { return "Unknown location" }
        return String(format: "%.2f, %.2f", coordinates.latitude, coordinates.longitude)
    }
}

// MARK: - Row

private struct PrayerRow: View {
    let prayer: Prayer
    let time: Date
    let isCurrent: Bool
    let isPast: Bool

    var body: some View {
        HStack {
            Text(prayer.displayName)
                .font(.footnote)
                // Sunrise is in the list because people plan around it, but it
                // is not a prayer, so it is visually demoted rather than given
                // equal weight.
                .foregroundStyle(prayer.isObligatoryPrayer ? .primary : .secondary)

            Spacer()

            Text(time, style: .time)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(isPast && !isCurrent ? .tertiary : .primary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.tint.opacity(0.25))
            }
        }
    }
}

// MARK: - States

private struct NoLocationState: View {
    let status: LocationProvider.Status

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "location.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tint)

            switch status {
            case .denied:
                Text("Location is off")
                    .font(.headline)
                Text("Awqat calculates times on this watch and never sends your position anywhere. Turn on location in Settings › Privacy to get started.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let reason):
                Text("Couldn't get a location")
                    .font(.headline)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            default:
                Text("Finding your location…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PolarDayNotice: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.max.trianglebadge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            Text("The sun does not rise or set here today")
                .font(.caption)
                .multilineTextAlignment(.center)
            Text("Sunrise and sunset have no solution at this latitude on this date, so no timetable can be calculated honestly. Scholars differ on what to follow; the usual practice is to use the times of the nearest place with a normal day, or Makkah.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 6)
    }
}
