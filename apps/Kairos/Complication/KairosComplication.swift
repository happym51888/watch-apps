import WidgetKit
import SwiftUI

/// A launcher, not a code display.
///
/// Putting a live code on the watch face is the obvious feature request and it
/// is the wrong call: a second factor that is legible to anyone glancing at
/// your wrist, in every photo you appear in, and on the always-on display while
/// the watch sits on a desk, is not a second factor. The complication gets you
/// to the code in one tap instead, which is still faster than reaching for a
/// phone.
///
/// The timeline is a single entry with a `.never` refresh policy. There is
/// nothing time-varying to show, so the widget never costs a refresh budget.
struct KairosComplication: Widget {
    let kind = "KairosLauncher"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("Kairos")
        .description("Open Kairos to read a code.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

struct LauncherEntry: TimelineEntry {
    let date: Date
}

struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Kairos", systemImage: "lock.rotation")

        case .accessoryCorner:
            Image(systemName: "lock.rotation")
                .font(.title2)
                .widgetLabel("Kairos")

        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "lock.rotation")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Kairos").font(.headline)
                    Text("Tap for a code")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .containerBackground(.clear, for: .widget)

        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "lock.rotation")
                    .font(.title3)
            }
            .containerBackground(.clear, for: .widget)
        }
    }
}

@main
struct KairosComplicationBundle: WidgetBundle {
    var body: some Widget {
        KairosComplication()
    }
}
