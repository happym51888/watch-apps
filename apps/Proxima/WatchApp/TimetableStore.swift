import Foundation
import WatchConnectivity

/// The slice on this watch, and the stops the rider cares about.
@MainActor
@Observable
final class TimetableStore: NSObject {

    private(set) var timetable: Timetable?
    private(set) var savedStops: [String] = []
    private(set) var lastError: String?
    private(set) var isReceiving = false

    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var sliceURL: URL { root.appendingPathComponent("slice.json") }
    private var stopsURL: URL { root.appendingPathComponent("stops.json") }

    override init() {
        super.init()
        load()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func load() {
        if let data = try? Data(contentsOf: sliceURL) {
            timetable = try? JSONDecoder().decode(Timetable.self, from: data)
            if timetable == nil {
                // A slice that will not decode is worse than none, because the
                // screen would otherwise look like an agency with no service.
                lastError = "The saved timetable could not be read. Send it again from your iPhone."
            }
        }
        if let data = try? Data(contentsOf: stopsURL),
           let stops = try? JSONDecoder().decode([String].self, from: data) {
            savedStops = stops
        }
        if savedStops.isEmpty, let timetable {
            // Whatever the phone compiled for is what the rider chose.
            savedStops = Array(timetable.departuresByStop.keys).sorted()
        }
    }

    func setStops(_ stops: [String]) {
        savedStops = stops
        if let data = try? JSONEncoder().encode(stops) {
            try? data.write(to: stopsURL, options: .atomic)
        }
    }

    /// How stale the slice is, for the screen that says so.
    var compiledDaysAgo: Int? {
        guard let compiledAt = timetable?.compiledAt else { return nil }
        return Int(Date().timeIntervalSince(compiledAt) / 86_400)
    }

    var validity: Validity? {
        guard let timetable else { return nil }
        return timetable.validity(on: timetable.localDate(at: Date()))
    }
}

extension TimetableStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Task { @MainActor in self.lastError = error.localizedDescription }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The temporary URL is deleted the moment this returns, so the copy
        // has to happen here rather than inside the Task below.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = base.appendingPathComponent("slice.json")

        // Decode before overwriting. A truncated transfer that replaces a good
        // slice with an unreadable one leaves the rider with nothing at the
        // stop, which is the one place they cannot fix it.
        guard let data = try? Data(contentsOf: file.fileURL),
              let decoded = try? JSONDecoder().decode(Timetable.self, from: data)
        else {
            Task { @MainActor in
                self.lastError = "The timetable that arrived could not be read; the old one is still here."
            }
            return
        }
        try? data.write(to: destination, options: .atomic)

        Task { @MainActor in
            self.timetable = decoded
            self.setStops(Array(decoded.departuresByStop.keys).sorted())
            self.lastError = nil
        }
    }
}
