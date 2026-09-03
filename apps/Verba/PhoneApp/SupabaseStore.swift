import Foundation

/// Minimal Supabase client, hand-rolled against the REST and Storage endpoints.
///
/// No SDK dependency on purpose. This app needs exactly three calls — sign in,
/// upload an object, upsert a row — and the official Swift package brings in a
/// realtime websocket stack and several transitive dependencies to provide
/// them. Three `URLRequest`s are easier to audit and cannot break on a
/// dependency bump.
///
/// Configuration comes from `Supabase.plist`, which is gitignored. The anon key
/// is safe to ship in a client — it is public by design — but only because Row
/// Level Security is doing the real work. If you copy this, read
/// `supabase/schema.sql` before you deploy: with RLS off, an anon key is a
/// world-readable database.
actor SupabaseStore {

    struct Configuration: Sendable {
        let url: URL
        let anonKey: String
        let bucket: String

        static func load() throws -> Configuration {
            guard let path = Bundle.main.url(forResource: "Supabase", withExtension: "plist"),
                  let data = try? Data(contentsOf: path),
                  let plist = try? PropertyListSerialization
                      .propertyList(from: data, format: nil) as? [String: String],
                  let raw = plist["url"], let url = URL(string: raw),
                  let key = plist["anonKey"]
            else {
                throw StoreError.notConfigured
            }
            return Configuration(url: url, anonKey: key, bucket: plist["bucket"] ?? "memo-audio")
        }
    }

    enum StoreError: LocalizedError {
        case notConfigured
        case notSignedIn
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Supabase.plist is missing. Copy Supabase.example.plist and fill it in."
            case .notSignedIn:
                "Sign in before syncing."
            case .http(let code, let body):
                "Server returned \(code). \(body)"
            }
        }
    }

    private let configuration: Configuration
    private var accessToken: String?
    private var userID: String?

    init() throws {
        self.configuration = try Configuration.load()
    }

    // MARK: - Auth

    func signIn(email: String, password: String) async throws {
        var request = URLRequest(url: configuration.url
            .appendingPathComponent("auth/v1/token"))
        request.url?.append(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfFailed(response, data)

        struct TokenResponse: Decodable {
            let access_token: String
            let user: User
            struct User: Decodable { let id: String }
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = decoded.access_token
        userID = decoded.user.id
    }

    var isSignedIn: Bool { accessToken != nil }

    // MARK: - Sync

    /// Upload the audio and upsert the row.
    ///
    /// Order matters: audio first, then the row that points at it. The reverse
    /// leaves a row referencing an object that may never arrive, and a list
    /// full of memos that cannot be played is worse than a list that is briefly
    /// short.
    func sync(
        recording: Recording,
        transcript: Transcript?,
        audio: URL?,
        sourceDevice: String
    ) async throws {
        guard let token = accessToken, let userID else { throw StoreError.notSignedIn }

        var audioPath: String?
        if let audio, FileManager.default.fileExists(atPath: audio.path) {
            audioPath = "\(userID)/\(recording.id.raw).m4a"
            try await uploadAudio(at: audio, to: audioPath!, token: token)
        }

        try await upsertRow(
            recording: recording,
            transcript: transcript,
            audioPath: audioPath,
            sourceDevice: sourceDevice,
            token: token
        )
    }

    private func uploadAudio(at url: URL, to path: String, token: String) async throws {
        var request = URLRequest(url: configuration.url
            .appendingPathComponent("storage/v1/object/\(configuration.bucket)/\(path)"))
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        // Re-uploading the same recording must overwrite rather than 409, since
        // redelivery is expected and is not an error anywhere else in the
        // pipeline.
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        // `upload(fromFile:)` streams from disk. Loading an hour of audio into
        // memory to hand it to `httpBody` is how a phone app gets jetsammed.
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: url)
        try Self.throwIfFailed(response, data)
    }

    private func upsertRow(
        recording: Recording,
        transcript: Transcript?,
        audioPath: String?,
        sourceDevice: String,
        token: String
    ) async throws {
        var request = URLRequest(url: configuration.url
            .appendingPathComponent("rest/v1/rpc/upsert_memo"))
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Calling the function rather than inserting directly, so the
        // "never blank a populated field" merge rule lives in one place —
        // the database — instead of being reimplemented per client.
        struct Parameters: Encodable {
            let p_id: String
            let p_started_at: Date
            let p_duration_seconds: Double
            let p_byte_count: Int
            let p_source_device: String
            let p_audio_path: String?
            let p_transcript: String?
            let p_transcript_locale: String?
            let p_transcript_engine: String?
            let p_transcript_confidence: Double?
            let p_title: String?
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(Parameters(
            p_id: recording.id.raw,
            p_started_at: recording.startedAt,
            p_duration_seconds: recording.duration,
            p_byte_count: recording.byteCount,
            p_source_device: sourceDevice,
            p_audio_path: audioPath,
            p_transcript: transcript?.text,
            p_transcript_locale: transcript?.locale,
            p_transcript_engine: transcript?.engine.rawValue,
            p_transcript_confidence: transcript?.confidence,
            p_title: transcript.map { Transcript.title(from: $0.text) }
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfFailed(response, data)
    }

    private static func throwIfFailed(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw StoreError.http(http.statusCode, String(body.prefix(300)))
    }
}
