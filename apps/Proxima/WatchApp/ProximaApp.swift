import SwiftUI

@main
struct ProximaApp: App {
    @State private var store = TimetableStore()

    var body: some Scene {
        WindowGroup {
            BoardView()
                .environment(store)
        }
    }
}

/// The board.
///
/// One screen, no navigation, no tabs. The realistic use is a glance at a
/// raised wrist in the rain, so the answer to "when is the next one" has to be
/// the first thing on it and has to be readable without focusing.
struct BoardView: View {
    @Environment(TimetableStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if let timetable = store.timetable {
                    board(timetable)
                } else {
                    NothingYet(error: store.lastError)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        guard let timetable = store.timetable else { return "Proxima" }
        return timetable.displayName(forStops: store.savedStops)
    }

    @ViewBuilder
    private func board(_ timetable: Timetable) -> some View {
        // A ticking clock rather than a one-shot render: "3 min" that stays at
        // "3 min" for a quarter of an hour is worse than no number, because it
        // is confidently wrong and looks fine.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let now = context.date
            let today = timetable.localDate(at: now)
            let validity = timetable.validity(on: today)
            let departures = validity == .current
                ? nextDepartures(timetable, stopIDs: store.savedStops, now: now, limit: 12)
                : []

            List {
                if validity != .current {
                    OutOfDateNotice(validity: validity, timetable: timetable)
                } else if departures.isEmpty {
                    // An empty board and a broken app look identical, so say
                    // which one this is.
                    Text("Nothing scheduled in the next 12 hours.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(departures) { departure in
                        DepartureRow(departure: departure, now: now, timetable: timetable)
                    }
                }

                Footer(timetable: timetable, store: store)
            }
        }
    }
}

private struct DepartureRow: View {
    let departure: Departure
    let now: Date
    let timetable: Timetable

    var body: some View {
        HStack(spacing: 8) {
            Text(departure.routeLabel)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minWidth: 34, alignment: .leading)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(departure.headsign.isEmpty ? "—" : departure.headsign)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(clockTime)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            countdown
        }
        .padding(.vertical, 1)
    }

    /// The scheduled time in the *feed's* zone, not the watch's.
    ///
    /// They are usually the same and occasionally not, and when they are not
    /// the rider wants the time on the platform sign, not the time at home.
    private var clockTime: String {
        let formatter = DateFormatter()
        formatter.timeZone = timetable.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: departure.when)
    }

    @ViewBuilder
    private var countdown: some View {
        let minutes = departure.minutesAway(from: now)
        if minutes == 0 {
            Text("now")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(minutes)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("m")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OutOfDateNotice: View {
    let validity: Validity
    let timetable: Timetable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                validity == .expired ? "Timetable has run out" : "Timetable starts later",
                systemImage: "calendar.badge.exclamationmark"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)

            if let span = timetable.coverage {
                Text("It covers \(span.start) to \(span.end). Send a fresh one from your iPhone.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Footer: View {
    let timetable: Timetable
    let store: TimetableStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timetable.agencyName)
            if let days = store.compiledDaysAgo {
                // Scheduled times, not live ones. Saying so is the difference
                // between a rider trusting a stale number and knowing to leave
                // a minute early.
                Text(days == 0 ? "Scheduled times, updated today" : "Scheduled times, updated \(days)d ago")
            }
            if let error = store.lastError {
                Text(error).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
    }
}

private struct NothingYet: View {
    let error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "tram.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("No timetable yet")
                    .font(.headline)
                Text("Open Proxima on your iPhone, pick your stops, and send them here. After that the watch works with no phone and no signal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let error {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
