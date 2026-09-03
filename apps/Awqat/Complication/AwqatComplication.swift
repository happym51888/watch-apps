import WidgetKit
import SwiftUI

/// Next prayer on the watch face.
///
/// This is the feature the incumbent's users complain has broken — "the widget
/// appears as just a blank square" — so the failure modes get more attention
/// here than the happy path.
///
/// Two decisions follow from that:
///
/// 1. **The complication never computes anything.** It reads a snapshot the app
///    wrote. Recomputing would need location permission in a second process and
///    could disagree with what the app is showing, which is exactly how you end
///    up with a widget nobody trusts.
/// 2. **A missing snapshot renders as readable text, not as nothing.** A blank
///    square is indistinguishable from a crash. "Open Awqat" is a instruction.
struct AwqatComplication: Widget {
    let kind = "AwqatNextPrayer"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextPrayerProvider()) { entry in
            NextPrayerView(entry: entry)
        }
        .configurationDisplayName("Next prayer")
        .description("The next prayer time and how long until it.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

struct NextPrayerEntry: TimelineEntry {
    let date: Date
    let prayerName: String?
    let prayerTime: Date?
}

struct NextPrayerProvider: TimelineProvider {

    func placeholder(in context: Context) -> NextPrayerEntry {
        NextPrayerEntry(date: .now, prayerName: "Asr", prayerTime: .now.addingTimeInterval(3600))
    }

    func getSnapshot(in context: Context, completion: @escaping (NextPrayerEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextPrayerEntry>) -> Void) {
        let entry = currentEntry()

        // Refresh when this prayer arrives, so the face rolls to the next one
        // without the user opening the app. `.after` rather than a poll: there
        // is exactly one moment at which this display becomes stale, and it is
        // known precisely.
        let policy: TimelineReloadPolicy = if let time = entry.prayerTime, time > .now {
            .after(time.addingTimeInterval(30))
        } else {
            .after(.now.addingTimeInterval(15 * 60))
        }

        completion(Timeline(entries: [entry], policy: policy))
    }

    private func currentEntry() -> NextPrayerEntry {
        guard let payload = SharedSnapshot.read() else {
            return NextPrayerEntry(date: .now, prayerName: nil, prayerTime: nil)
        }
        return NextPrayerEntry(
            date: .now,
            prayerName: payload.prayerName,
            prayerTime: payload.time
        )
    }
}

struct NextPrayerView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextPrayerEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            if let name = entry.prayerName, let time = entry.prayerTime {
                Text("\(name) \(time, style: .time)")
            } else {
                Text("Open Awqat")
            }

        case .accessoryCorner:
            Group {
                if let time = entry.prayerTime {
                    Text(time, style: .time).font(.title3)
                } else {
                    Image(systemName: "moon.stars")
                }
            }
            .widgetLabel(entry.prayerName ?? "Awqat")

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                if let name = entry.prayerName, let time = entry.prayerTime {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(time, style: .time)
                        .font(.title3.weight(.semibold))
                    Text(time, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Awqat").font(.headline)
                    Text("Open to set your location")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .containerBackground(.clear, for: .widget)

        default:
            ZStack {
                AccessoryWidgetBackground()
                if let name = entry.prayerName, let time = entry.prayerTime {
                    VStack(spacing: -1) {
                        Text(name.prefix(4))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(time, style: .time)
                            .font(.system(size: 13, weight: .semibold))
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    Image(systemName: "moon.stars")
                }
            }
            .containerBackground(.clear, for: .widget)
        }
    }
}

@main
struct AwqatComplicationBundle: WidgetBundle {
    var body: some Widget {
        AwqatComplication()
    }
}
