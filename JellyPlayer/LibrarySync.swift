import Foundation
import UIKit

/// "Download all": keeps every song of the chosen folder saved on the phone, one at a time, and keeps
/// checking the server for new songs. While it's on, the cache size limit is ignored.
@MainActor
final class LibrarySync: ObservableObject {
    enum Status: Equatable {
        case off
        case checking
        case downloading
        case waiting(String)     // a problem, will retry
        case paused(String)      // not allowed to run right now
        case complete
    }

    /// How often the server folder is checked for new songs.
    private static let checkInterval: TimeInterval = 5 * 60

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: AudioCache.keepAllKey)
            if enabled { run() } else { stop() }
        }
    }
    @Published private(set) var status: Status = .off
    /// Songs in the folder, and how many of them are saved.
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    /// The song downloading now, how far along it is (0…1), and its size so far.
    @Published private(set) var currentName: String?
    @Published private(set) var currentFraction: Double = 0
    @Published private(set) var currentBytes: Int64 = 0
    /// Bytes of saved songs on disk (finished ones).
    @Published private(set) var savedBytes: Int64 = 0
    /// Songs in a format that can't be saved for offline play.
    @Published private(set) var skipped = 0
    @Published private(set) var lastChecked: Date?

    private let client: JellyfinClient
    private let cache: AudioCache
    /// Set by the app model: the folder's songs, a server refresh, and whether going online is allowed.
    var songs: () -> [JFItem] = { [] }
    var refresh: () async -> Void = {}
    var isOffline: () -> Bool = { false }

    private var task: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var unsupported = Set<String>()
    private let downloader = FileDownloader()

    init(client: JellyfinClient, cache: AudioCache) {
        self.client = client
        self.cache = cache
        enabled = UserDefaults.standard.bool(forKey: AudioCache.keepAllKey)
    }

    /// Overall progress from 0 to 1, counting the part of the current song that's in.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(done) + (currentName == nil ? 0 : currentFraction)) / Double(total))
    }

    /// Call once the app has loaded, and whenever the folder's song list changes.
    func songsChanged() {
        guard enabled else { return }
        if task == nil { run() } else { sleeper?.cancel() }
    }

    private func stop() {
        task?.cancel()
        task = nil
        sleeper?.cancel()
        downloader.cancel()
        currentName = nil
        status = .off
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func run() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        var failures = 0
        while !Task.isCancelled, enabled {
            if isOffline() {
                recount()
                status = .paused("Paused while Play saved songs only is on")
                await sleep(60)
                continue
            }
            // Look at the server folder again every few minutes, so new songs get picked up.
            if lastChecked == nil || Date().timeIntervalSince(lastChecked!) > Self.checkInterval {
                if recount().isEmpty { status = .checking }
                await refresh()
                lastChecked = Date()
                if Task.isCancelled { return }
            }
            let pending = recount()
            guard let song = pending.first else {
                currentName = nil
                status = total == 0 ? .waiting("No songs in this folder yet") : .complete
                UIApplication.shared.isIdleTimerDisabled = false
                await sleep(Self.checkInterval)
                continue
            }
            guard let url = client.directStreamURL(for: song) else {
                status = .waiting("Not signed in")
                await sleep(30)
                continue
            }

            status = .downloading
            currentName = song.name
            currentFraction = 0
            currentBytes = 0
            // Keep the screen from locking mid-download: iOS pauses the app soon after it locks.
            UIApplication.shared.isIdleTimerDisabled = true
            let result = await downloader.download(url, headers: client.streamHeaders) { [weak self] received, expected in
                Task { @MainActor in
                    guard let self, self.currentName == song.name else { return }
                    self.currentBytes = received
                    if expected > 0 { self.currentFraction = min(1, Double(received) / Double(expected)) }
                }
            }
            if Task.isCancelled { return }
            switch result {
            case .success(let file):
                if cache.adopt(file.url, songId: song.id, mimeType: file.mimeType, fileName: file.suggestedName) {
                    failures = 0
                    // Covers too, so the list and the car have them offline.
                    let big = client.imageURLs(for: song, size: 600)
                    let small = client.imageURLs(for: song, size: 150)
                    Task.detached {
                        _ = await ImageCache.shared.image(for: big)
                        _ = await ImageCache.shared.image(for: small)
                    }
                } else {
                    try? FileManager.default.removeItem(at: file.url)
                    unsupported.insert(song.id)
                }
            case .failure(let message):
                failures += 1
                currentName = nil
                UIApplication.shared.isIdleTimerDisabled = false
                // A server answer like "not found" won't change by retrying this song right away.
                if message.hasPrefix("HTTP 4") { unsupported.insert(song.id) }
                status = .waiting("\(message). Trying again soon")
                await sleep(min(5 * pow(2, Double(failures - 1)), 60))
            }
        }
    }

    /// Updates the counts and returns the songs still to download.
    @discardableResult
    private func recount() -> [JFItem] {
        let all = songs()
        let saved = cache.cachedSongIds()
        let pending = all.filter { !saved.contains($0.id) && !unsupported.contains($0.id) }
        total = all.count
        skipped = all.filter { unsupported.contains($0.id) && !saved.contains($0.id) }.count
        done = all.count - pending.count - skipped
        savedBytes = cache.diskSize
        return pending
    }

    /// Sleeps, but wakes early when the song list changes.
    private func sleep(_ seconds: TimeInterval) async {
        let sleeper = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        self.sleeper = sleeper
        await sleeper.value
    }
}

/// Downloads one file to a temporary place, reporting progress. Waits for the network if there is none.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct File {
        let url: URL
        let mimeType: String
        let suggestedName: String
    }
    enum Outcome {
        case success(File)
        case failure(String)
    }

    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var finished: Outcome?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL, headers: [String: String],
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async -> Outcome {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.progress = progress
            self.finished = nil
            let task = session.downloadTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock(); let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let progress = self.progress; lock.unlock()
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it somewhere of our own first.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var outcome: Outcome
        if status == 200 {
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                outcome = .success(File(url: kept,
                                        mimeType: downloadTask.response?.mimeType?.lowercased() ?? "",
                                        suggestedName: downloadTask.response?.suggestedFilename ?? ""))
            } catch {
                outcome = .failure("Couldn't save the file")
            }
        } else {
            outcome = .failure("HTTP \(status)")
        }
        lock.lock(); finished = outcome; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.progress = nil
        self.task = nil
        var outcome = finished
        finished = nil
        lock.unlock()
        if let error { outcome = .failure((error as NSError).localizedDescription) }
        continuation?.resume(returning: outcome ?? .failure("Download ended early"))
    }
}
