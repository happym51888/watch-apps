import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import WatchConnectivity

@main
struct VolumenPhoneApp: App {
    @State private var sender = Sender()

    var body: some Scene {
        WindowGroup {
            ImportView()
                .environment(sender)
        }
    }
}

/// Pick DRM-free audio files, group them into a book, send them to the watch.
///
/// There is no store, no account and no catalogue. The files come from the
/// user's own Files app — LibriVox downloads, Internet Archive, a bought MP3
/// bundle, anything without DRM. An app that cannot open the user's existing
/// library is not a player, it is a shop.
struct ImportView: View {
    @Environment(Sender.self) private var sender
    @State private var picking = false
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Book title", text: $title)
                    Button {
                        picking = true
                    } label: {
                        Label("Choose audio files", systemImage: "folder.badge.plus")
                    }
                } footer: {
                    Text("DRM-free files only. Files are sorted the way they are named, so numbered chapters arrive in order.")
                }

                if !sender.staged.isEmpty {
                    Section("Ready to send") {
                        ForEach(sender.staged, id: \.url) { file in
                            HStack {
                                Text(file.url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(file.duration)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.footnote)
                        }
                        Button {
                            sender.send(title: title)
                        } label: {
                            Label("Send to Apple Watch", systemImage: "applewatch.radiowaves.left.and.right")
                        }
                        .disabled(title.isEmpty || !sender.isWatchReachable)
                    }
                }

                if !sender.inFlight.isEmpty {
                    Section("Sending") {
                        ForEach(sender.inFlight, id: \.self) { name in
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(name).font(.footnote).lineLimit(1)
                            }
                        }
                    }
                }

                Section {
                    Label(
                        sender.isWatchReachable ? "Watch is paired" : "Watch not reachable",
                        systemImage: sender.isWatchReachable ? "applewatch" : "applewatch.slash"
                    )
                    .foregroundStyle(sender.isWatchReachable ? .primary : .secondary)
                    .font(.footnote)
                } footer: {
                    Text("Transfers continue in the background. A long book can take a while over Bluetooth; keeping both devices on the same Wi-Fi is much faster.")
                }

                if let error = sender.lastError {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Volumen")
            .fileImporter(
                isPresented: $picking,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                allowsMultipleSelection: true
            ) { result in
                Task { await sender.stage(result) }
            }
        }
    }
}

/// Staging and transfer.
@MainActor
@Observable
final class Sender: NSObject {

    struct Staged: Sendable {
        let url: URL
        let durationMS: Int64
        var duration: String {
            let total = Int(durationMS / 1000)
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
    }

    private(set) var staged: [Staged] = []
    private(set) var inFlight: [String] = []
    private(set) var isWatchReachable = false
    private(set) var lastError: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func stage(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
        case .success(let urls):
            var found: [Staged] = []
            for url in urls {
                // Files chosen through the picker live outside the sandbox and
                // need the scoped access opened around every read, including
                // the metadata read below.
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }

                let asset = AVURLAsset(url: url)
                guard let duration = try? await asset.load(.duration) else { continue }
                found.append(
                    Staged(url: url, durationMS: Int64((duration.seconds * 1000).rounded()))
                )
            }
            // Numeric-aware ordering, so "Chapter 10" follows "Chapter 9"
            // rather than "Chapter 1".
            staged = found.sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                    == .orderedAscending
            }
        }
    }

    func send(title: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        // A folder name, not a display name: it has to survive being a path
        // component and has to be the same every time this book is sent, so
        // that re-sending a missing chapter joins the existing book instead of
        // creating a second one.
        let bookID = slug(title)

        // The manifest travels first so the watch can name the book even if
        // only some of the audio has arrived.
        if let manifest = try? JSONEncoder().encode(
            ["title": title]
        ) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("book.json")
            try? manifest.write(to: url, options: .atomic)
            session.transferFile(url, metadata: ["bookID": bookID, "name": "book.json"])
        }

        for (index, file) in staged.enumerated() {
            guard file.url.startAccessingSecurityScopedResource() else { continue }
            defer { file.url.stopAccessingSecurityScopedResource() }

            // Copied into the app's own container first. WatchConnectivity
            // reads the file asynchronously, after this function has returned
            // and the scoped access has been closed again.
            let name = String(format: "%04d-%@", index + 1, file.url.lastPathComponent)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: staging)
            do {
                try FileManager.default.copyItem(at: file.url, to: staging)
            } catch {
                lastError = error.localizedDescription
                continue
            }
            inFlight.append(name)
            session.transferFile(staging, metadata: ["bookID": bookID, "name": name])
        }
        staged = []
    }

    private func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).replacingOccurrences(of: "--", with: "-").lowercased()
    }
}

// MARK: - WCSessionDelegate

extension Sender: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let paired = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in self.isWatchReachable = paired }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in self.isWatchReachable = paired }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let name = (fileTransfer.file.metadata?["name"] as? String)
            ?? fileTransfer.file.fileURL.lastPathComponent
        let message = error?.localizedDescription
        let source = fileTransfer.file.fileURL
        Task { @MainActor in
            self.inFlight.removeAll { $0 == name }
            if let message { self.lastError = "\(name): \(message)" }
            // The staging copy has done its job either way. Leaving it behind
            // means a fifty-hour book occupies the phone twice.
            try? FileManager.default.removeItem(at: source)
        }
    }
}
