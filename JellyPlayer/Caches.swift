import CryptoKit
import Foundation
import UIKit

/// A folder for saved songs, covers or song lists. It lives in Application Support, which iOS never
/// empties on its own (the Caches folder can be cleared when the phone runs low on space, which would
/// break playing offline). Kept out of iCloud/iTunes backups. Files saved by earlier versions in Caches
/// are moved over.
private func cachesDirectory(_ name: String) -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var dir = base.appendingPathComponent(name, isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
    let old = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    if let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
        for file in files {
            try? fm.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        try? fm.removeItem(at: old)
    }
    return dir
}

private func hashedName(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func directorySize(_ dir: URL) -> Int64 {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}

// MARK: - Cover art

/// Cover art cache: memory first, then disk. Remembers URLs that had no image so fallbacks don't refetch them.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let directory = cachesDirectory("covers")
    private let lock = NSLock()
    /// URLs that had no image, with when we tried. Retried after a while, because some servers fetch art on demand.
    private var missing: [URL: Date] = [:]
    private static let retryAfter: TimeInterval = 120

    private init() {
        memory.countLimit = 400
    }

    private func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(hashedName(url.absoluteString))
    }

    /// Instant lookup (memory only) for the first available candidate, used to avoid a placeholder flash.
    func memoryImage(for urls: [URL]) -> UIImage? {
        for url in urls {
            if let image = memory.object(forKey: url as NSURL) { return image }
            if !isMissing(url) { return nil }
        }
        return nil
    }

    /// Loads the first candidate that has an image: memory, then disk, then network (saved to disk).
    func image(for urls: [URL]) async -> UIImage? {
        for url in urls {
            if Task.isCancelled { return nil }
            if let image = await image(for: url) { return image }
        }
        return nil
    }

    private func image(for url: URL) async -> UIImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        if isMissing(url) { return nil }

        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: url as NSURL)
            return image
        }

        let label = Self.label(url)
        let started = Date()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(from: url)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DiagLog.shared.add("  image \(label): network error \((error as NSError).code) after \(ms) ms")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard status == 200, let image = UIImage(data: data) else {
            DiagLog.shared.add("  image \(label): HTTP \(status), \(data.count) bytes, \(ms) ms, not usable")
            // Only a clear "not found" counts as no image; anything else (e.g. a flaky connection) is retried.
            if status == 404 { lock.withLock { missing[url] = Date() } }
            return nil
        }
        DiagLog.shared.add("  image \(label): downloaded \(data.count / 1024) KB in \(ms) ms")
        try? data.write(to: file, options: .atomic)
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Covers wait for the network to come up (e.g. a VPN still connecting right after launch) instead of
    /// failing at once, but give up after 20 s so the caller can try again.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// Short name for the log: "<start of item id> @<size>".
    private static func label(_ url: URL) -> String {
        let parts = url.pathComponents
        let id = parts.count > 2 ? String(parts[parts.count - 3].prefix(8)) : "?"
        let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "maxWidth" }?.value ?? "?"
        return "\(id) @\(size)"
    }

    /// Forgets "this URL has no image" marks, so the playing song's cover is asked for again right away.
    func forgetMissing(_ urls: [URL]) {
        lock.withLock { urls.forEach { missing[$0] = nil } }
    }

    private func isMissing(_ url: URL) -> Bool {
        lock.withLock {
            guard let since = missing[url] else { return false }
            if Date().timeIntervalSince(since) > Self.retryAfter {
                missing[url] = nil
                return false
            }
            return true
        }
    }

    var diskSize: Int64 { directorySize(directory) }

    func clear() {
        memory.removeAllObjects()
        lock.withLock { missing.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - Audio

/// Keeps played songs on the device so they start instantly and play offline.
/// Least recently played files are removed once the cache passes `maxBytes`.
@MainActor
final class AudioCache {
    static let limitKey = "cacheLimitGB"
    static let defaultLimitGB = 1.0

    /// Size limit chosen in Settings (1 GB unless changed).
    static var maxBytes: Int64 {
        let gb = UserDefaults.standard.object(forKey: limitKey) as? Double ?? defaultLimitGB
        return Int64(gb * 1_000_000_000)
    }

    /// Set by "Download all": keep every song and ignore the size limit.
    static let keepAllKey = "downloadAll"
    static var keepsAll: Bool { UserDefaults.standard.bool(forKey: keepAllKey) }

    private let directory = cachesDirectory("audio")
    private var inFlight = Set<String>()

    private static let extensions: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3",
        "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a", "audio/aac": "aac",
        "audio/flac": "flac", "audio/x-flac": "flac",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav",
        "audio/aiff": "aiff", "audio/x-aiff": "aiff",
    ]

    /// The saved file for a song, if it has been cached. Marks it as recently used.
    func localFile(for songId: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.deletingPathExtension().lastPathComponent == songId }) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    /// Ids of every saved song, from one directory listing.
    func cachedSongIds() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(files.map { $0.deletingPathExtension().lastPathComponent })
    }

    func isCached(_ songId: String) -> Bool {
        localFile(for: songId) != nil
    }

    /// Downloads the original file in the background, unless it's already saved or downloading.
    func store(songId: String, from url: URL, headers: [String: String]) {
        guard !inFlight.contains(songId), !isCached(songId) else { return }
        inFlight.insert(songId)
        let directory = directory
        Task {
            defer { inFlight.remove(songId) }
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            guard let (temp, response) = try? await URLSession.shared.download(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let mime = http.mimeType?.lowercased(),
                  let ext = Self.extensions[mime] else { return }
            let destination = directory.appendingPathComponent("\(songId).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            guard (try? FileManager.default.moveItem(at: temp, to: destination)) != nil else { return }
            evictIfNeeded()
        }
    }

    /// Takes over a finished download (used by "Download all"). Returns false if the format can't be kept.
    func adopt(_ file: URL, songId: String, mimeType: String, fileName: String) -> Bool {
        let known = Set(Self.extensions.values)
        let fromName = (fileName as NSString).pathExtension.lowercased()
        guard let ext = Self.extensions[mimeType] ?? (known.contains(fromName) ? fromName : nil) else { return false }
        let destination = directory.appendingPathComponent("\(songId).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        return (try? FileManager.default.moveItem(at: file, to: destination)) != nil
    }

    /// Saves a song that was downloaded while it played.
    func save(_ data: Data, songId: String, mimeType: String) {
        guard let ext = Self.extensions[mimeType.lowercased()], !isCached(songId) else { return }
        let destination = directory.appendingPathComponent("\(songId).\(ext)")
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return }
        evictIfNeeded()
    }

    /// Removes the least recently played songs until the cache fits the limit.
    func evictIfNeeded() {
        guard !Self.keepsAll else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .map { url -> (url: URL, size: Int64, date: Date) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
            }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > Self.maxBytes else { return }
        files.sort { $0.date < $1.date }
        for file in files where total > Self.maxBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    var diskSize: Int64 { directorySize(directory) }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - Song list

/// Saves the last loaded song list per folder so the app can show it (and start playing) instantly.
enum SongListCache {
    private static let directory = cachesDirectory("songs")

    private static func file(for folderId: String) -> URL {
        directory.appendingPathComponent("\(folderId).json")
    }

    static func load(folderId: String) -> [JFItem]? {
        guard let data = try? Data(contentsOf: file(for: folderId)) else { return nil }
        return try? JSONDecoder().decode([JFItem].self, from: data)
    }

    static func save(_ songs: [JFItem], folderId: String) {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        try? data.write(to: file(for: folderId), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
