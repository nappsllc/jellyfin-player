import CryptoKit
import Foundation
import UIKit

private func cachesDirectory(_ name: String) -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let image = UIImage(data: data) else {
            // Only a clear "not found" counts as no image; anything else (e.g. a flaky connection) is retried.
            if status == 404 { lock.withLock { missing[url] = Date() } }
            return nil
        }
        try? data.write(to: file, options: .atomic)
        memory.setObject(image, forKey: url as NSURL)
        return image
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

    /// Saves a song that was downloaded while it played.
    func save(_ data: Data, songId: String, mimeType: String) {
        guard let ext = Self.extensions[mimeType.lowercased()], !isCached(songId) else { return }
        let destination = directory.appendingPathComponent("\(songId).\(ext)")
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return }
        evictIfNeeded()
    }

    /// Removes the least recently played songs until the cache fits the limit.
    func evictIfNeeded() {
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
