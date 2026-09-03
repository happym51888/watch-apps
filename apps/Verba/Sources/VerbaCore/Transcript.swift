import Foundation

/// A finished transcription, as it is stored and synced.
///
/// Lives in the shared core rather than in the phone target because the watch
/// displays it too (mirrored back after the phone transcribes), and because the
/// database row shape should be defined in exactly one place.
public struct Transcript: Sendable, Codable, Equatable, Identifiable {
    public var id: RecordingID { recordingID }

    public let recordingID: RecordingID
    public let text: String
    /// BCP-47, e.g. "zh-CN". Recorded because re-transcribing later with a
    /// better model needs to know what was assumed the first time.
    public let locale: String
    /// Which engine produced this. On-device and cloud results differ enough in
    /// quality that mixing them without a label makes the corpus untrustworthy.
    public let engine: Engine
    public let createdAt: Date
    /// Mean confidence in 0...1 where the engine reports it. `nil` when it does
    /// not, which is not the same as zero and must not be rendered as such.
    public let confidence: Double?

    public enum Engine: String, Sendable, Codable, Equatable {
        /// Apple's `SpeechAnalyzer`, iOS 26+. On-device, free, private.
        case appleOnDevice
        /// Apple's older `SFSpeechRecognizer`. May be server-backed depending
        /// on `requiresOnDeviceRecognition` and the locale's model.
        case appleLegacy
        /// A cloud model reached from an Edge Function.
        case cloud
        /// Typed or corrected by the user. Never overwritten by a machine.
        case manual
    }

    public init(
        recordingID: RecordingID,
        text: String,
        locale: String,
        engine: Engine,
        createdAt: Date = Date(),
        confidence: Double? = nil
    ) {
        self.recordingID = recordingID
        self.text = text
        self.locale = locale
        self.engine = engine
        self.createdAt = createdAt
        self.confidence = confidence
    }

    /// First line of a transcript, for list rows and complications.
    ///
    /// Truncates on a word boundary where there is one within reach, because a
    /// title cut mid-word reads as a bug. Falls back to a hard cut for scripts
    /// without spaces — Chinese and Japanese have no word boundaries to find,
    /// and a hard cut there is normal and correct.
    public static func title(from text: String, limit: Int = 40) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }

        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        guard firstLine.count > limit else { return firstLine }

        let cut = firstLine.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > limit / 2 {
            return String(cut[cut.startIndex..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }
}

/// One row as the database sees it. Kept separate from `Transcript` and
/// `Recording` so a schema change is a change to this file and nothing else.
public struct MemoRow: Sendable, Codable, Equatable {
    public let id: String
    public let started_at: Date
    public let duration_seconds: Double
    public let byte_count: Int
    public let source_device: String
    public let audio_path: String?
    public let transcript: String?
    public let transcript_locale: String?
    public let transcript_engine: String?
    public let transcript_confidence: Double?
    public let title: String?

    public init(
        recording: Recording,
        transcript: Transcript?,
        sourceDevice: String,
        audioPath: String?
    ) {
        self.id = recording.id.raw
        self.started_at = recording.startedAt
        self.duration_seconds = recording.duration
        self.byte_count = recording.byteCount
        self.source_device = sourceDevice
        self.audio_path = audioPath
        self.transcript = transcript?.text
        self.transcript_locale = transcript?.locale
        self.transcript_engine = transcript?.engine.rawValue
        self.transcript_confidence = transcript?.confidence
        self.title = transcript.map { Transcript.title(from: $0.text) } ?? recording.title
    }
}
