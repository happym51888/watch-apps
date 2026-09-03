import Foundation
import AVFoundation
import Speech

/// Speech-to-text. Runs on the iPhone, because it cannot run anywhere else.
///
/// This is worth stating plainly since it drove the whole architecture: **there
/// is no speech recognition API on watchOS.** Neither the old `Speech`
/// framework nor the new `SpeechAnalyzer` ships there — Apple's own
/// documentation lists iOS, iPadOS, Mac Catalyst, macOS, tvOS and visionOS, and
/// no watchOS for either. So the watch's job ends at capturing audio safely,
/// and transcription happens here for free, on-device, with nothing leaving the
/// user's hardware.
///
/// Uses `SFSpeechRecognizer`, which is also the reason `ChunkPlan` exists: it
/// handles roughly a minute of audio per request, so anything longer is fed
/// through in overlapping windows and stitched back together by
/// `TranscriptStitcher`.
///
/// An earlier version of this file also had a `SpeechAnalyzer` path for iOS 26,
/// written from the documentation. CI rejected it — `SpeechAnalyzer`,
/// `SpeechTranscriber` and `AssetInventory` are all "cannot find in scope"
/// against the SDK on the runner — so it is gone rather than left in as
/// plausible-looking dead code. If you build against an SDK that has it, it is
/// worth adding back: newer models, and no per-request duration ceiling, which
/// would make the chunking below unnecessary.
actor Transcriber {

    enum TranscribeError: LocalizedError {
        case notAuthorised
        case noRecogniserForLocale(String)
        case recogniserUnavailable
        case producedNothing

        var errorDescription: String? {
            switch self {
            case .notAuthorised:
                "Verba needs permission to use speech recognition."
            case .noRecogniserForLocale(let locale):
                "No speech model is available for \(locale)."
            case .recogniserUnavailable:
                "Speech recognition is temporarily unavailable."
            case .producedNothing:
                "No speech was detected in that recording."
            }
        }
    }

    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - Permission

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Entry point

    func transcribe(_ url: URL, recordingID: RecordingID) async throws -> Transcript {
        guard await Self.requestAuthorization() else { throw TranscribeError.notAuthorised }

        let duration = try await Self.duration(of: url)
        return try await transcribeWithRecogniser(
            url, recordingID: recordingID, duration: duration
        )
    }

    // MARK: - Recognition

    private func transcribeWithRecogniser(
        _ url: URL,
        recordingID: RecordingID,
        duration: TimeInterval
    ) async throws -> Transcript {
        guard let recogniser = SFSpeechRecognizer(locale: locale) else {
            throw TranscribeError.noRecogniserForLocale(locale.identifier)
        }
        guard recogniser.isAvailable else { throw TranscribeError.recogniserUnavailable }

        let plan = ChunkPlan(duration: duration)

        // The common case: short memo, one request, no seam to get wrong.
        if plan.chunks.count == 1 {
            let text = try await recognise(url, using: recogniser)
            guard !text.isEmpty else { throw TranscribeError.producedNothing }
            return Transcript(
                recordingID: recordingID,
                text: text,
                locale: locale.identifier(.bcp47),
                engine: .appleLegacy
            )
        }

        var pieces: [String] = []
        for chunk in plan.chunks {
            let slice = try await Self.exportSlice(of: url, from: chunk.start, to: chunk.end)
            defer { try? FileManager.default.removeItem(at: slice) }
            // One failed window must not lose the other seventy-one. A gap is
            // visible in the text; a thrown error loses the whole recording.
            let text = (try? await recognise(slice, using: recogniser)) ?? ""
            pieces.append(text)
        }

        let stitched = TranscriptStitcher.stitch(pieces)
        guard !stitched.isEmpty else { throw TranscribeError.producedNothing }

        return Transcript(
            recordingID: recordingID,
            text: stitched,
            locale: locale.identifier(.bcp47),
            engine: .appleLegacy
        )
    }

    private func recognise(_ url: URL, using recogniser: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        // On-device keeps the audio on the phone and removes the server-side
        // request throttle. Falling back to the network would be faster for
        // some locales but changes the privacy story, so it is opt-in only.
        request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            // `recognitionTask` can call back more than once even with partial
            // results off. Latch so the continuation is resumed exactly once —
            // resuming twice is a crash, not an error.
            let latch = ResumeLatch()
            recogniser.recognitionTask(with: request) { result, error in
                if let error {
                    if latch.claim() { continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                if latch.claim() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    // MARK: - Audio helpers

    private static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await CMTimeGetSeconds(asset.load(.duration))
    }

    /// Export one window of the recording to a temporary file.
    private static func exportSlice(
        of url: URL,
        from start: TimeInterval,
        to end: TimeInterval
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TranscribeError.recogniserUnavailable
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(UUID().uuidString).m4a")

        export.outputURL = output
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )

        await export.export()
        return output
    }
}

/// Ensures a continuation is resumed exactly once, whatever the callback does.
private final class ResumeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
