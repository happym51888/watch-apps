import SwiftUI
import WidgetKit

/// One-tap access from the watch face to the last tempo used.
///
/// Deliberately static. A complication gets a limited refresh budget per day, and
/// there is nothing here that changes on its own — the tempo only moves when the
/// user moves it, and the app refreshes the timeline when that happens. So a single
/// never-expiring entry is both correct and free, instead of burning the budget on
/// a value that was already right.
struct TactusEntry: TimelineEntry {
    let date: Date
    let bpm: Int
    let meter: String
}

struct TactusProvider: TimelineProvider {
    func placeholder(in context: Context) -> TactusEntry {
        TactusEntry(date: .now, bpm: 120, meter: "4/4")
    }

    func getSnapshot(in context: Context, completion: @escaping (TactusEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TactusEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> TactusEntry {
        let settings = Storage.settings ?? MetronomeSettings(bpm: 100)
        return TactusEntry(
            date: .now,
            bpm: Int(settings.bpm),
            meter: "\(settings.timeSignature.beatsPerBar)/\(settings.timeSignature.beatUnit)"
        )
    }
}

struct TactusComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TactusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: -2) {
                Text("\(entry.bpm)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                Text("bpm")
                    .font(.system(size: 9))
            }
            .containerBackground(.fill.tertiary, for: .widget)

        case .accessoryCorner:
            Text("\(entry.bpm)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .widgetLabel("bpm \(entry.meter)")
                .containerBackground(.fill.tertiary, for: .widget)

        case .accessoryInline:
            Text("\(entry.bpm) bpm · \(entry.meter)")

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Tactus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(entry.bpm) bpm")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(entry.meter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)

        @unknown default:
            Text("\(entry.bpm)")
        }
    }
}

@main
struct TactusComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TactusComplication", provider: TactusProvider()) { entry in
            TactusComplicationView(entry: entry)
        }
        .configurationDisplayName("Tempo")
        .description("Your last tempo, one tap away.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}
