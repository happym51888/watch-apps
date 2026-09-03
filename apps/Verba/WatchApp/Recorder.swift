import Foundation
import AVFoundation
import Observation
import WatchKit
import VerbaCore

/// Audio capture on the watch.
///
/// Two platform facts shape everything here, and both were verified against
/// Apple's documentation rather than assumed:
///
/// **1. Recording cannot be started from the background.** The `audio`
/// background mode only permits *continuing* audio I/O that began while the app
/// was frontmost. Any attempt to start it from a timer or a background task
/// fails with `AVAudioSession` error 561015905. So there is no "always-on
/// pocket recorder" to build — there is a button, and the button must be one
/// tap away. Everything about the UI follows from this.
///
/// **2. Once started, it keeps going.** With `audio` in `WKBackgroundModes`,
/// lowering your wrist, letting the screen sleep, or switching apps does not
/// stop the recording. That is the actual user need — "record the rest of this
/// conversation" — and it is fully supported.
///
/// Note this uses the plain `audio` background mode, not an extended runtime
/// session. A recorder recording audio is exactly what that mode is for, so
/// there is no review argument to have.
@MainActor
@Observable
final class Recorder {

    enum State: Equatable {
        case idle
        case preparing
        case recording(since: Date)
        case stopping
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Live input level in 0...1, for the waveform. Updated a few times a
    /// second while the screen is on; not worth computing when it is off.
    private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var currentID: RecordingID?
    private var currentURL: URL?
    private var currentStartedAt: Date?
    private var levelTimer: Timer?

    /// Called with the finished recording once the file is closed and sized.
    var onFinished: ((Recording, URL) -> Void)?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Start

    func start() {
        guard !isRecording else { return }
        state = .preparing

        Task {
            guard await requestPermission() else {
                state = .denied
                return
            }
            beginCapture()
        }
    }

    private func beginCapture() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` mode tunes the input chain for speech rather than
            // music, which is what the transcriber downstream wants.
            // `.allowBluetooth` lets AirPods be the microphone, which on a
            // wrist-worn device is a large quality difference.
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetooth, .duckOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            state = .failed("Couldn't start the microphone. \(error.localizedDescription)")
            return
        }

        let startedAt = Date()
        let id = RecordingID(startedAt: startedAt, entropy: Self.entropy())
        let url = AudioFiles.url(for: id)

        // 16 kHz mono AAC. Speech recognisers downsample to 16 kHz anyway, so
        // anything higher costs watch storage and transfer time to deliver
        // information the transcriber discards. An hour lands around 15 MB.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else {
                state = .failed("The microphone refused to start.")
                return
            }
            recorder = newRecorder
            currentID = id
            currentURL = url
            currentStartedAt = startedAt
            state = .recording(since: startedAt)

            // Confirm by touch. The user is about to put their wrist down and
            // needs to know it caught, without looking.
            WKInterfaceDevice.current().play(.start)
            startLevelUpdates()
        } catch {
            state = .failed("Couldn't create the recording. \(error.localizedDescription)")
        }
    }

    // MARK: - Stop

    func stop() {
        guard isRecording,
              let recorder,
              let id = currentID,
              let url = currentURL,
              let startedAt = currentStartedAt
        else { return }

        state = .stopping
        stopLevelUpdates()

        // Read the duration before stopping: `currentTime` reports zero once
        // the recorder is stopped.
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil

        WKInterfaceDevice.current().play(.stop)

        // Size the file *after* stop() returns, since the encoder flushes its
        // tail on close and a size read before that is short.
        let byteCount = AudioFiles.byteCount(at: url)

        let recording = Recording(
            id: id,
            startedAt: startedAt,
            duration: duration,
            byteCount: byteCount
        )

        currentID = nil
        currentURL = nil
        currentStartedAt = nil
        state = .idle

        // Deactivating the session lets other audio resume. Non-fatal if it
        // fails, and it must not block handing the recording to the queue.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        onFinished?(recording, url)
    }

    // MARK: - Metering

    private func startLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // dBFS is roughly -60 (silence) to 0 (clipping). Mapping it
                // linearly makes normal speech sit near the bottom of the bar,
                // so the curve is shaped to put speech in the visible range.
                let decibels = Double(recorder.averagePower(forChannel: 0))
                let normalised = max(0, min(1, (decibels + 50) / 50))
                self.level = pow(normalised, 0.6)
            }
        }
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 0
    }

    private static func entropy() -> String {
        // Six base32 characters. Enough to make a same-second collision
        // effectively impossible without carrying a full UUID in every
        // filename, database key and bucket path.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

/// Where audio lives on the watch.
enum AudioFiles {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(for id: RecordingID) -> URL {
        directory.appendingPathComponent("\(id.raw).m4a")
    }

    static func exists(_ id: RecordingID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Zero for a missing or unreadable file, which the queue then treats as a
    /// recording with no audio rather than crashing on it.
    static func byteCount(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    static func delete(_ id: RecordingID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
