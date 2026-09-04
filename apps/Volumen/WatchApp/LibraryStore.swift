import Foundation
import AVFoundation
import WatchConnectivity

/// The books on this watch, and where you are in each of them.
///
/// Two responsibilities that look separable and are not: a place is only
/// meaningful against a particular set of files, so the thing that discovers
/// files has to be the thing that resolves places against them. Splitting them
/// is how a bookmark ends up resolved against a library that has already
/// changed underneath it.
@MainActor
@Observable
final class LibraryStore: NSObject {

    private(set) var books: [Book] = []
    /// The library as it was when places were last saved. Kept so that a
    /// bookmark whose file has since been deleted can still be rebased against
    /// the arrangement it was written for, rather than dumped at chapter one.
    private(set) var previousBooks: [String: Book] = [:]
    private(set) var receiving: Set<String> = []
    private(set) var lastError: String?

    private var places: [String: Bookmark] = [:]

    private let fileManager = FileManager.default

    private var root: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Books", isDirectory: true)
    }

    private var placesURL: URL { root.appendingPathComponent("places.json") }
    private var shelfURL: URL { root.appendingPathComponent("shelf.json") }

    override init() {
        super.init()
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        loadPlaces()
        Task { await rescan() }
        activateSession()
    }

    // MARK: - Places

    func place(in book: Book) -> Bookmark? { places[book.id] }

    /// Write a place down.
    ///
    /// Called on pause, on every file transition, and on the periodic tick —
    /// anywhere that could be the last thing that happens before watchOS
    /// suspends and then kills the app. The file is small and the write is
    /// atomic, so doing it often costs nothing worth saving.
    func save(_ mark: Bookmark, for book: Book) {
        places[book.id] = mark
        persistPlaces()
    }

    private func loadPlaces() {
        guard let data = try? Data(contentsOf: placesURL) else { return }
        places = (try? JSONDecoder().decode([String: Bookmark].self, from: data)) ?? [:]

        // The shelf as it was when those places were written.
        if let shelfData = try? Data(contentsOf: shelfURL),
           let shelf = try? JSONDecoder().decode([StoredBook].self, from: shelfData) {
            for stored in shelf {
                if let book = try? stored.asBook() { previousBooks[book.id] = book }
            }
        }
    }

    private func persistPlaces() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        // `.atomic` matters more here than anywhere else in the app: a partial
        // write leaves unparseable JSON, and unparseable JSON loses every
        // place in the library at once rather than just the current one.
        try? data.write(to: placesURL, options: .atomic)
        persistShelf()
    }

    private func persistShelf() {
        let shelf = books.map(StoredBook.init)
        guard let data = try? JSONEncoder().encode(shelf) else { return }
        try? data.write(to: shelfURL, options: .atomic)
    }

    // MARK: - Scanning

    /// Rebuild the library from what is on disk.
    ///
    /// Durations come from AVFoundation rather than from any sidecar file,
    /// because a sidecar written on the phone describes the file the phone
    /// had. If a transfer truncated, only the audio itself knows.
    func rescan() async {
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []

        var found: [Book] = []
        for directory in directories.filter({ $0.hasDirectoryPath }) {
            if let book = await loadBook(at: directory) { found.append(book) }
        }
        books = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        persistShelf()
    }

    private func loadBook(at directory: URL) async -> Book? {
        let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "caf"]
        let files = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            // Sorted by name, and numerically where the names are numbered:
            // plain lexical order puts chapter 10 before chapter 2, which
            // silently reorders most of a long book.
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !files.isEmpty else { return nil }

        var tracks: [Track] = []
        for file in files {
            guard let track = await track(for: file) else { continue }
            tracks.append(track)
        }
        guard !tracks.isEmpty else { return nil }

        let manifest = try? JSONDecoder().decode(
            BookManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("book.json"))
        )
        return try? Book(
            id: directory.lastPathComponent,
            title: manifest?.title ?? directory.lastPathComponent,
            tracks: tracks,
            // Recorded so the disagreement can be shown, never used to place
            // the listener.
            declaredTotalMS: manifest?.declaredTotalMS
        )
    }

    private func track(for url: URL) async -> Track? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let ms = Int64((duration.seconds * 1000).rounded())
        guard ms > 0 else { return nil }

        guard let id = identity(of: url) else { return nil }
        let title = (try? await asset.load(.metadata))?
            .first { $0.commonKey == .commonKeyTitle }
            .flatMap { $0.stringValue } ?? url.deletingPathExtension().lastPathComponent

        return try? Track(id: id, title: title, durationMS: ms)
    }

    /// A stable id for a file: a hash of its head plus its exact length.
    ///
    /// Reading only the head keeps this cheap enough to run over the whole
    /// library at launch; including the length is what stops a truncated
    /// transfer from inheriting the complete file's bookmarks.
    private func identity(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let prefix: Data = (try? handle.read(upToCount: TrackIdentity.probeLength)).flatMap { $0 } ?? Data()
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return TrackIdentity.make(prefix: [UInt8](prefix), totalBytes: size)
    }

    // MARK: - Receiving from the phone

    private func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func delete(_ book: Book) {
        try? fileManager.removeItem(at: root.appendingPathComponent(book.id))
        // The place is deliberately kept. Deleting a book to free space and
        // re-downloading it later is normal, and the id is derived from the
        // file's bytes, so the place is still exact when it comes back.
        Task { await rescan() }
    }
}

// MARK: - Transfers

extension LibraryStore: WCSessionDelegate {
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
        // WatchConnectivity deletes the temporary URL as soon as this returns,
        // so the move has to happen here and synchronously — not inside the
        // Task below, which would find nothing there.
        let metadata = file.metadata ?? [:]
        let bookID = (metadata["bookID"] as? String) ?? "Unsorted"
        let name = (metadata["name"] as? String) ?? file.fileURL.lastPathComponent

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookID, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        let moved = (try? FileManager.default.moveItem(at: file.fileURL, to: destination)) != nil

        Task { @MainActor in
            if moved {
                self.receiving.remove(name)
                await self.rescan()
            } else {
                self.lastError = "Could not store \(name)"
            }
        }
    }
}

// MARK: - Persisted shapes

/// What the phone writes alongside the audio.
private struct BookManifest: Codable {
    let title: String
    /// The publisher's stated running time, if it gave one. Present only so
    /// the app can point out when it disagrees with the files.
    let declaredTotalMS: Int64?
}

/// A book as it was when places were last written, so a bookmark can be
/// rebased against the arrangement it was made in.
private struct StoredBook: Codable {
    struct StoredTrack: Codable {
        let id: String
        let title: String
        let durationMS: Int64
    }

    let id: String
    let title: String
    let tracks: [StoredTrack]

    init(_ book: Book) {
        self.id = book.id
        self.title = book.title
        self.tracks = book.tracks.map {
            StoredTrack(id: $0.id, title: $0.title, durationMS: $0.durationMS)
        }
    }

    func asBook() throws -> Book {
        try Book(
            id: id,
            title: title,
            tracks: tracks.map { try Track(id: $0.id, title: $0.title, durationMS: $0.durationMS) }
        )
    }
}
