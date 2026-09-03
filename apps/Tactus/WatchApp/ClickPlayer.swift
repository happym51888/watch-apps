import AVFoundation
import Foundation

/// Optional audible click, played to the watch speaker or to connected headphones.
///
/// Two reasons it exists beyond "some people want to hear it":
///
/// 1. It is the officially sanctioned way to keep running with the wrist down.
///    The background audio mode grants runtime for as long as real audio is
///    actually playing, with none of the review risk attached to borrowing an
///    extended-runtime session type.
/// 2. Above roughly 176 bpm the haptic plan has to start thinning taps. Audio has
///    no such rate limit, so the click can carry the subdivisions the wrist cannot.
///
/// Timing note: buffers are scheduled as each pulse fires rather than pre-rendered
/// onto the audio timeline, so the click inherits the same millisecond-level
/// scheduling jitter as the haptic. That is fine for practice and wrong for
/// recording to a click track; pre-scheduling onto `AVAudioTime` is the upgrade
/// path if anyone ever needs sample accuracy.
final class ClickPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [HapticStrength: AVAudioPCMBuffer] = [:]
    private var isPrepared = false

    /// Distinct pitches so a downbeat is recognisable without counting.
    private static let frequencies: [HapticStrength: Double] = [
        .strong: 1600,
        .medium: 1100,
        .light: 800
    ]

    func prepare() throws {
        guard !isPrepared else { return }

        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])

        let format = engine.outputNode.outputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        for strength in HapticStrength.allCases {
            buffers[strength] = Self.makeClick(
                frequency: Self.frequencies[strength] ?? 1000,
                format: format
            )
        }

        engine.prepare()
        try engine.start()
        player.play()
        isPrepared = true
    }

    /// watchOS will not route audio until the session is activated, and activation
    /// is asynchronous and can be refused (for instance with no output route
    /// available). Failure here is not fatal — the haptics carry the beat.
    func activateSession() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().activate(options: []) { activated, _ in
                continuation.resume(returning: activated)
            }
        }
    }

    func play(_ strength: HapticStrength) {
        guard isPrepared, let buffer = buffers[strength] else { return }
        // `.interrupts` keeps a slow tempo from queueing clicks behind each other
        // if a previous one has not finished.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    func stop() {
        guard isPrepared else { return }
        player.stop()
        engine.stop()
        isPrepared = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// A short sine burst with an exponential decay — a percussive click rather
    /// than a beep, which is easier to place rhythmically.
    private static func makeClick(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration = 0.035
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let decay = 55.0
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let value = Float(sin(2 * .pi * frequency * t) * exp(-decay * t) * 0.9)
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel][frame] = value
            }
        }
        return buffer
    }
}
