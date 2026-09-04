import SwiftUI
import WatchConnectivity

@main
struct ProximaPhoneApp: App {
    @State private var builder = SliceBuilder()

    var body: some Scene {
        WindowGroup {
            BuildSliceView()
                .environment(builder)
        }
    }
}

/// Fetch a published GTFS feed, pick the stops you use, send them to the watch.
///
/// All of this happens once, on the phone, where there is a keyboard and a
/// battery. Afterwards the watch answers offline and the phone is not involved
/// at all — which is the point, because the moment you need a departure time is
/// the moment you are not holding a phone.
struct BuildSliceView: View {
    @Environment(SliceBuilder.self) private var builder
    @State private var feedURL = ""
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("GTFS feed URL", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await builder.load(from: feedURL) }
                    } label: {
                        Label("Download feed", systemImage: "arrow.down.circle")
                    }
                    .disabled(feedURL.isEmpty || builder.isWorking)
                } header: {
                    Text("Agency feed")
                } footer: {
                    Text("The static GTFS zip your transit agency publishes. Most link it from an open-data page; look for \"GTFS\" or \"static schedule\".")
                }

                if builder.isWorking {
                    Section { ProgressView(builder.progress) }
                }

                if !builder.stops.isEmpty {
                    Section("Stops") {
                        TextField("Search stops", text: $search)
                        ForEach(matching) { stop in
                            Button {
                                builder.toggle(stop.stopID)
                            } label: {
                                HStack {
                                    Image(
                                        systemName: builder.selected.contains(stop.stopID)
                                            ? "checkmark.circle.fill" : "circle"
                                    )
                                    VStack(alignment: .leading) {
                                        Text(stop.name).lineLimit(1)
                                        if stop.isStation {
                                            Text("station — includes its platforms")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if !builder.selected.isEmpty {
                    Section {
                        Button {
                            Task { await builder.compileAndSend() }
                        } label: {
                            Label(
                                "Send \(builder.selected.count) stops to Apple Watch",
                                systemImage: "applewatch.radiowaves.left.and.right"
                            )
                        }
                        .disabled(builder.isWorking || !builder.isWatchReady)
                    } footer: {
                        if let summary = builder.summary { Text(summary) }
                    }
                }

                if let error = builder.error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Proxima")
        }
    }

    /// Capped at 40 rows. A national feed has tens of thousands of stops and a
    /// watch-paired phone list that tries to show them all stops scrolling.
    private var matching: [Stop] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return Array(builder.stops.prefix(40)) }
        let hits = builder.stops.filter { $0.name.lowercased().contains(query) }
        return Array(hits.prefix(40))
    }
}

@MainActor
@Observable
final class SliceBuilder: NSObject {

    private(set) var stops: [Stop] = []
    private(set) var selected: Set<String> = []
    private(set) var isWorking = false
    private(set) var progress = ""
    private(set) var error: String?
    private(set) var summary: String?
    private(set) var isWatchReady = false

    private var texts: FeedTexts?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func toggle(_ stopID: String) {
        if selected.contains(stopID) { selected.remove(stopID) } else { selected.insert(stopID) }
        summary = nil
    }

    func load(from urlText: String) async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
            error = "That is not a URL."
            return
        }
        isWorking = true
        error = nil
        summary = nil
        progress = "Downloading…"
        defer { isWorking = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FeedError("the server answered \(http.statusCode)")
            }

            progress = "Reading the archive…"
            let entries = try ZipReader.index(data)

            func text(_ name: String) throws -> String {
                // Some publishers nest the files in a folder inside the zip.
                guard let entry = entries.first(where: {
                    $0.name == name || $0.name.hasSuffix("/" + name)
                }) else { return "" }
                return String(decoding: try ZipReader.extract(entry, from: data), as: UTF8.self)
            }

            let texts = FeedTexts(
                agency: try text("agency.txt"),
                stops: try text("stops.txt"),
                routes: try text("routes.txt"),
                trips: try text("trips.txt"),
                stopTimes: try text("stop_times.txt"),
                calendar: try text("calendar.txt"),
                calendarDates: try text("calendar_dates.txt"),
                feedInfo: try text("feed_info.txt")
            )
            guard !texts.agency.isEmpty, !texts.stops.isEmpty, !texts.stopTimes.isEmpty else {
                throw FeedError("that zip does not contain a GTFS feed")
            }
            self.texts = texts

            let csv = CSV(texts.stops)
            // Stations first, then plain stops: picking a station is almost
            // always what a rider means, and it brings its platforms with it.
            stops = csv.rows.compactMap { row -> Stop? in
                let id = csv.value(row, "stop_id").trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty else { return nil }
                return Stop(
                    stopID: id,
                    name: csv.value(row, "stop_name"),
                    parentStation: csv.value(row, "parent_station").trimmingCharacters(in: .whitespaces),
                    locationType: csv.int(row, "location_type")
                )
            }
            .sorted {
                $0.isStation != $1.isStation
                    ? $0.isStation
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            selected = []
            progress = ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func compileAndSend() async {
        guard let texts, !selected.isEmpty else { return }
        isWorking = true
        error = nil
        progress = "Compiling…"
        defer { isWorking = false }

        do {
            let table = try SliceCompiler.compile(texts, stopIDs: Array(selected))
            let departures = table.departuresByStop.values.reduce(0) { $0 + $1.count }
            guard departures > 0 else {
                throw FeedError("no boardable departures at those stops — try a station rather than a platform")
            }

            let data = try JSONEncoder().encode(table)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("slice.json")
            try data.write(to: url, options: .atomic)

            var note = "\(departures) departures, \(table.trips.count) trips, \(data.count / 1024) KB."
            if let span = table.coverage {
                note += " Timetable runs \(span.start) to \(span.end)."
            }
            if table.declarationDisagrees {
                note += " The publisher's stated validity disagrees with its own calendars; the calendars were used."
            }
            summary = note

            WCSession.default.transferFile(url, metadata: ["kind": "slice"])
            progress = ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

// MARK: - WCSessionDelegate

extension SliceBuilder: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let ready = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in self.isWatchReady = ready }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let ready = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in self.isWatchReady = ready }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message { self.error = message } else { self.summary = "Sent to the watch." }
        }
    }
}
