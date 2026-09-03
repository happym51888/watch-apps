import SwiftUI
import WatchConnectivity

/// The iPhone side. It does the two things the watch physically cannot:
/// transcribe (no speech API exists on watchOS) and hold a long-lived network
/// session comfortably.
@main
struct VerbaPhoneApp: App {
    @State private var inbox = Inbox()

    var body: some Scene {
        WindowGroup {
            InboxView()
                .environment(inbox)
                .task { await inbox.start() }
        }
    }
}

// MARK: - Inbox

/// Receives files from the watch, transcribes them, syncs them, and — crucially
/// — does not delete anything until all three have succeeded.
@MainActor
@Observable
final class Inbox: NSObject {

    struct Entry: Identifiable, Equatable {
        let id: RecordingID
        var recording: Recording
        var transcript: Transcript?
        var localAudio: URL?
        var stage: Stage

        enum Stage: Equatable {
            case received
            case transcribing
            case transcribed
            case syncing
            case synced
            case failed(String)
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var isSignedIn = false
    private(set) var configurationError: String?

    private var store: SupabaseStore?
    private let transcriber = Transcriber()

    func start() async {
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }

        do {
            store = try SupabaseStore()
        } catch {
            configurationError = error.localizedDescription
        }

        _ = await Transcriber.requestAuthorization()
    }

    func signIn(email: String, password: String) async {
        guard let store else { return }
        do {
            try await store.signIn(email: email, password: password)
            isSignedIn = true
            // Anything that piled up while signed out can now go.
            await drainUnsynced()
        } catch {
            configurationError = error.localizedDescription
        }
    }

    // MARK: - Pipeline

    /// Everything the phone needs from an incoming transfer, in `Sendable` form.
    ///
    /// `WCSessionFile` and its `[String: Any]` metadata are not `Sendable`, so
    /// they cannot be handed from the `nonisolated` delegate callback into a
    /// `@MainActor` task — Swift 6 rejects it as a data race. The delegate
    /// flattens what it needs into this while still on the calling thread.
    struct IncomingTransfer: Sendable {
        let id: RecordingID
        let fileURL: URL
        let startedAt: Date
        let duration: TimeInterval
    }

    fileprivate func ingest(_ incoming: IncomingTransfer) {
        let destination = InboxFiles.url(for: incoming.id)

        let recording = Recording(
            id: incoming.id,
            startedAt: incoming.startedAt,
            duration: incoming.duration,
            byteCount: InboxFiles.byteCount(at: destination),
            state: .delivered
        )

        upsert(Entry(
            id: incoming.id,
            recording: recording,
            transcript: nil,
            localAudio: destination,
            stage: .received
        ))

        Task { await process(incoming.id) }
    }

    private func process(_ id: RecordingID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        guard let audio = entry.localAudio else { return }

        // Transcribe.
        if entry.transcript == nil {
            update(id) { $0.stage = .transcribing }
            do {
                let transcript = try await transcriber.transcribe(audio, recordingID: id)
                update(id) {
                    $0.transcript = transcript
                    $0.recording.title = Transcript.title(from: transcript.text)
                    $0.stage = .transcribed
                }
            } catch {
                // A failed transcription is not a failed recording. The audio
                // is safe and syncs anyway; the text can be retried or typed.
                update(id) { $0.stage = .failed(error.localizedDescription) }
            }
        }

        await sync(id)
    }

    private func sync(_ id: RecordingID) async {
        guard let store, isSignedIn else { return }
        guard let entry = entries.first(where: { $0.id == id }) else { return }

        update(id) { $0.stage = .syncing }
        do {
            try await store.sync(
                recording: entry.recording,
                transcript: entry.transcript,
                audio: entry.localAudio,
                sourceDevice: "watch"
            )
            update(id) { $0.stage = .synced }
        } catch {
            update(id) { $0.stage = .failed(error.localizedDescription) }
        }
    }

    func retry(_ id: RecordingID) {
        Task { await process(id) }
    }

    private func drainUnsynced() async {
        for entry in entries where entry.stage != .synced {
            await process(entry.id)
        }
    }

    // MARK: - Entry bookkeeping

    private func upsert(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
            entries.sort { $0.recording.startedAt > $1.recording.startedAt }
        }
    }

    private func update(_ id: RecordingID, _ mutate: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[index])
    }

    private func append(failure: String, id: RecordingID) {
        upsert(Entry(
            id: id,
            recording: Recording(id: id, startedAt: Date()),
            transcript: nil,
            localAudio: nil,
            stage: .failed(failure)
        ))
    }
}

// MARK: - WCSessionDelegate

extension Inbox: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        guard let raw = metadata["recordingID"] as? String else { return }
        let id = RecordingID(raw: raw)

        // The copy happens here, synchronously, and not in the task that
        // follows. WatchConnectivity reclaims its temporary inbox as soon as
        // this method returns, so a copy deferred onto the actor races the
        // system deleting the file — and loses, intermittently, which is the
        // worst way to lose a recording.
        let destination = InboxFiles.url(for: id)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                self.append(failure: "Couldn't save the incoming recording. \(message)", id: id)
            }
            return
        }

        let incoming = IncomingTransfer(
            id: id,
            fileURL: destination,
            startedAt: metadata["startedAt"] as? Date ?? Date(),
            duration: metadata["duration"] as? TimeInterval ?? 0
        )

        Task { @MainActor in self.ingest(incoming) }
    }
}

enum InboxFiles {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(for id: RecordingID) -> URL {
        directory.appendingPathComponent("\(id.raw).m4a")
    }

    static func byteCount(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }
}

// MARK: - UI

struct InboxView: View {
    @Environment(Inbox.self) private var inbox
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            List {
                if let error = inbox.configurationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if !inbox.isSignedIn {
                    Section("Sign in to sync") {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        Button("Sign in") {
                            Task { await inbox.signIn(email: email, password: password) }
                        }
                        .disabled(email.isEmpty || password.isEmpty)
                    }
                }

                Section(inbox.entries.isEmpty ? "" : "Recordings") {
                    if inbox.entries.isEmpty {
                        Text("Recordings from your Apple Watch appear here, get transcribed on this iPhone, then sync.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(inbox.entries) { entry in
                        EntryRow(entry: entry) { inbox.retry(entry.id) }
                    }
                }
            }
            .navigationTitle("Verba")
        }
    }
}

private struct EntryRow: View {
    let entry: Inbox.Entry
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.transcript?.text ?? "—")
                .font(.body)
                .lineLimit(3)

            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(label)
                Spacer()
                Text(entry.recording.startedAt, style: .time)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if case .failed = entry.stage {
                Button("Try again", action: onRetry)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.stage {
        case .received: "tray.and.arrow.down"
        case .transcribing: "waveform"
        case .transcribed: "text.quote"
        case .syncing: "arrow.up.circle"
        case .synced: "checkmark.icloud"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        if case .failed = entry.stage { return .orange }
        if case .synced = entry.stage { return .green }
        return .secondary
    }

    private var label: String {
        switch entry.stage {
        case .received: "received from watch"
        case .transcribing: "transcribing on this iPhone…"
        case .transcribed: "transcribed"
        case .syncing: "syncing…"
        case .synced: "saved"
        case .failed(let reason): reason
        }
    }
}
