import Foundation

struct JellyfinSession: Codable, Equatable {
    var serverURL: URL
    var userId: String
    var userName: String
    var accessToken: String
}

enum JellyfinError: LocalizedError {
    case invalidURL
    case notSignedIn
    case badCredentials
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That server address doesn't look right. Try something like http://192.168.1.10:8096."
        case .notSignedIn: return "You're not signed in to Jellyfin."
        case .badCredentials: return "Wrong username or password."
        case .http(let code): return "The server answered with an error (HTTP \(code))."
        }
    }
}

/// Minimal Jellyfin REST client: sign in, browse folders, list songs, build stream and image URLs.
@MainActor
final class JellyfinClient {
    static let clientName = "JellyPlayer"
    static let clientVersion = "1.0"

    var session: JellyfinSession?
    let deviceId: String
    private let urlSession: URLSession

    init() {
        let key = "deviceId"
        if let id = UserDefaults.standard.string(forKey: key) {
            deviceId = id
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
            deviceId = id
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        urlSession = URLSession(configuration: config)
    }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    /// Headers for AVPlayer requests, so the stream is authorized even if the server ignores query-string tokens.
    var streamHeaders: [String: String] {
        guard let token = session?.accessToken else { return [:] }
        return ["Authorization": authorization(token: token), "X-Emby-Token": token]
    }

    private func authorization(token: String?) -> String {
        var value = "MediaBrowser Client=\"\(Self.clientName)\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"\(Self.clientVersion)\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    private func requireSession() throws -> JellyfinSession {
        guard let session else { throw JellyfinError.notSignedIn }
        return session
    }

    // MARK: Auth

    func authenticate(server: String, username: String, password: String) async throws -> JellyfinSession {
        guard let base = Self.normalize(server) else { throw JellyfinError.invalidURL }
        var request = URLRequest(url: base.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])

        let (data, response) = try await urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw JellyfinError.badCredentials }
        guard (200..<300).contains(code) else { throw JellyfinError.http(code) }

        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        let newSession = JellyfinSession(serverURL: base, userId: auth.user.id, userName: auth.user.name, accessToken: auth.accessToken)
        session = newSession
        return newSession
    }

    // MARK: Browsing

    /// Top-level libraries ("views") for the signed-in user.
    func libraries() async throws -> [JFItem] {
        let s = try requireSession()
        let response: JFItemsResponse = try await get("Users/\(s.userId)/Views", [])
        return response.items
    }

    /// Direct child folders of a library or folder.
    func folders(in parentId: String) async throws -> [JFItem] {
        let s = try requireSession()
        let response: JFItemsResponse = try await get("Items", [
            URLQueryItem(name: "userId", value: s.userId),
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "IsFolder", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
        ])
        return response.items.filter { $0.isFolder != false }
    }

    /// Every song inside a folder, including subfolders.
    func songs(in parentId: String) async throws -> [JFItem] {
        let s = try requireSession()
        var all: [JFItem] = []
        let pageSize = 500
        while true {
            let response: JFItemsResponse = try await get("Items", [
                URLQueryItem(name: "userId", value: s.userId),
                URLQueryItem(name: "ParentId", value: parentId),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "SortBy", value: "AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary"),
                URLQueryItem(name: "StartIndex", value: String(all.count)),
                URLQueryItem(name: "Limit", value: String(pageSize)),
            ])
            all += response.items
            let total = response.totalRecordCount ?? all.count
            if response.items.isEmpty || all.count >= total { break }
        }
        return all
    }

    // MARK: URLs

    /// The original file, streamed as-is with byte-range support. iOS plays MP3, AAC/M4A, ALAC, FLAC and WAV
    /// this way, and it avoids server-side HLS transcoding, which some servers (e.g. Remux) serve broken.
    func directStreamURL(for item: JFItem) -> URL? {
        guard let s = session else { return nil }
        var components = URLComponents(url: s.serverURL.appending(path: "Audio/\(item.id)/stream"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "ApiKey", value: s.accessToken),
            URLQueryItem(name: "api_key", value: s.accessToken),
        ]
        return components?.url
    }

    /// Fallback for formats iOS can't decode (e.g. Ogg, Opus, WMA): the server transcodes to AAC over HLS.
    func transcodedStreamURL(for item: JFItem) -> URL? {
        guard let s = session else { return nil }
        var components = URLComponents(url: s.serverURL.appending(path: "Audio/\(item.id)/universal"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "UserId", value: s.userId),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "ApiKey", value: s.accessToken),
            URLQueryItem(name: "api_key", value: s.accessToken),
            URLQueryItem(name: "Container", value: "mp3,aac,m4a|aac,m4b|aac,flac,alac,m4a|alac,wav"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "140000000"),
        ]
        return components?.url
    }

    /// Cover art for a song (falls back to its album's cover) or a folder.
    func imageURL(for item: JFItem, size: Int = 300) -> URL? {
        guard let s = session else { return nil }
        let id: String
        let tag: String
        if let t = item.imageTags?["Primary"] {
            id = item.id; tag = t
        } else if let albumId = item.albumId, let t = item.albumPrimaryImageTag {
            id = albumId; tag = t
        } else {
            return nil
        }
        var components = URLComponents(url: s.serverURL.appending(path: "Items/\(id)/Images/Primary"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(size)),
            URLQueryItem(name: "maxHeight", value: String(size)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag),
        ]
        return components?.url
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        let s = try requireSession()
        guard var components = URLComponents(url: s.serverURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw JellyfinError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(authorization(token: s.accessToken), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw JellyfinError.notSignedIn }
        guard (200..<300).contains(code) else { throw JellyfinError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
