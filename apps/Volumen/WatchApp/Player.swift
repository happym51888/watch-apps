import Foundation
import AVFoundation
import Observation

/// Drives `PlaybackState` from an `AVAudioPlayer`, and vice versa.
///
/// All of the arithmetic lives in `PlaybackState`, which is tested. This class
/// exists only to turn its actions into AVFoundation calls and to feed real
/// playback positions back in, so that the part of the app that can be
/// silently wrong is also the part that runs on Linux under `swift test`.
@MainActor
@Observable
final class Player: NSObject {

    private(set) var state: PlaybackState?
    private(set) var book: Book?
    /// Set when a saved place could not be honoured exactly. Shown to the
    /// listener rather than swallowed 鈥?landing somewhere unexplained is worse
    /// than landing somewhere explained.
    private(set) var jumpNotice: String?
    private(set) var failure: String?

    private var audio: AVAudioPlayer?
    private var ticker: Timer?
    private var lastTick: Date?
    private weak var library: LibraryStore?

    private var directory: URL? {
        guard let book else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(book.id, isDirectory: true)
    }

    // MARK: - Opening

    func open(_ book: Book, in library: LibraryStore) {
        self.book = book
        self.library = library
        jumpNotice = nil
        failure = nil

        let (state, actions) = PlaybackState.open(
            book: book,
            saved: library.place(in: book),
            previous: library.previousBooks[book.id]
        )
        self.state = state
        perform(actions)
    }

    // MARK: - Transport, called from the UI

    func togglePlayPause() {
        guard var state = self.state else { return }
        let actions = state.isPlaying ? state.pause() : state.play()
        self.state = state
        perform(actions)
    }

    func skip(_ seconds: Int) {
        guard var state = self.state else { return }
        let actions = state.skip(byMS: Int64(seconds) * 1000)
        self.state = state
        perform(actions)
    }

    func seek(toFraction fraction: Double) {
        guard var state = self.state, let book else { return }
        let target = Int64((Double(book.totalMS) * fraction).rounded())
        let actions = state.seek(toAbsoluteMS: target)
        self.state = state
        perform(actions)
    }

    func jump(toChapter index: Int) {
        guard var state = self.state else { return }
        let actions = state.jump(toChapter: index)
        self.state = state
        perform(actions)
    }

    func setSleepTimer(_ timer: SleepTimer) {
        guard var state = self.state else { return }
        state.setSleepTimer(timer)
        self.state = state
    }

    func dismissNotice() { jumpNotice = nil }

    // MARK: - Acting

    private func perform(_ actions: [PlaybackAction]) {
        for action in actions {
            switch action {
            case .load(let trackID, let offsetMS):
                load(trackID: trackID, offsetMS: offsetMS)
            case .play:
                startAudio()
            case .pause:
                audio?.pause()
                stopTicking()
            case .persist(let mark):
                if let book { library?.save(mark, for: book) }
            case .reportJump(_, _, let reason):
                jumpNotice = switch reason {
                case .trackMissing:
                    "That file is no longer on the watch. Moved to the nearest point."
                case .offsetPastEnd:
                    "The file was shorter than expected. Moved to its end."
                }
            case .fadeOutAndPause:
                fadeOutAndPause()
            }
        }
    }

    private func load(trackID: String, offsetMS: Int64) {
        guard let book, let directory,
              let index = book.index(ofTrack: trackID) else { return }

        // The file is found by matching its identity, not by index into a
        // directory listing 鈥?the listing can have changed since the book was
        // built, and an index would then open the wrong chapter.
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        guard let url = candidates.first(where: { fileMatches($0, trackID: trackID) }) else {
            failure = "Missing audio for \(book.tracks[index].title)"
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.prepareToPlay()
            player.currentTime = Double(offsetMS) / 1000
            audio = player
            if state?.isPlaying == true { startAudio() }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func fileMatches(_ url: URL, trackID: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix: Data = (try? handle.read(upToCount: TrackIdentity.probeLength)).flatMap { $0 } ?? Data()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return TrackIdentity.make(prefix: [UInt8](prefix), totalBytes: size) == trackID
    }

    private func startAudio() {
        audio?.play()
        startTicking()
    }

    private func fadeOutAndPause() {
        // Two seconds, so a listener who is still awake is not startled by the
        // book cutting off mid-word.
        audio?.setVolume(0, fadeDuration: 2)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.audio?.pause()
            // Volume back up, or the next play is silent and looks like a
            // broken file rather than a timer that already fired.
            self.audio?.volume = 1
            self.stopTicking()
        }
    }

    // MARK: - The clock

    /// One second. Fast enough that the position on screen is honest, slow
    /// enough that the watch is not woken pointlessly; the place is written
    /// down on every tick, so at most one second of progress is ever lost to a
    /// kill.
    private func startTicking() {
        stopTicking()
        lastTick = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        lastTick = nil
    }

    private func tick() {
        guard var state = self.state, let audio else { return }
        let now = Date()
        // Elapsed playing time is measured between ticks rather than assumed
        // to be one second, because a timer on watchOS is not punctual and the
        // sleep timer must not drift against the audio it is timing.
        let elapsed = Int64(((lastTick.map { now.timeIntervalSince($0) } ?? 1) * 1000).rounded())
        lastTick = now

        let actions = state.tick(
            offsetMS: Int64((audio.currentTime * 1000).rounded()),
            elapsedMS: elapsed
        )
        self.state = state
        perform(actions)

        if let book, let mark = self.state?.mark { library?.save(mark, for: book) }
    }
}

// MARK: - AVAudioPlayerDelegate

extension Player: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard var state = self.state else { return }
            let actions = state.trackDidEnd()
            self.state = state
            self.perform(actions)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "Could not decode this file"
        Task { @MainActor in self.failure = message }
    }
}
