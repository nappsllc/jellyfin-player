import AVFoundation
import MediaPlayer
import UIKit

/// Plays a queue of Jellyfin songs with AVPlayer, keeps playing in the background,
/// and drives the lock screen / Control Center controls.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var current: JFItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    /// How much of the current song is on the device or buffered, from 0 to 1 (like YouTube's grey bar).
    @Published private(set) var loaded: Double = 0
    /// Set when playback fails, so the UI can show why.
    @Published var errorMessage: String?

    private(set) var shuffleEnabled = false
    private var queue: [JFItem] = []
    private var originalOrder: [JFItem] = []
    private var index = 0
    private var consecutiveFailures = 0
    private var lastFailure: String?
    private var usingTranscode = false
    private var playingLocalFile = false
    let audioCache = AudioCache()
    private var loader: DownloadingLoader?
    /// Save played songs (and the next one in the queue) on the device.
    var cacheAudio = true

    private let player = AVPlayer()
    private let client: JellyfinClient
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    /// Finished car/lock-screen artwork for the playing and next song, kept strongly by song id.
    /// The image memory cache is emptied when the app goes to the background (screen off), so relying on it
    /// meant the next cover often had to be fetched again over a sleepy connection, and missed the car.
    private var preparedArtwork: [String: MPMediaItemArtwork] = [:]

    init(client: JellyfinClient) {
        self.client = client
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
    }

    // MARK: Public controls

    /// Start playing `songs`. With shuffle on the order is randomized (the tapped song still plays first).
    func play(songs: [JFItem], startAt song: JFItem? = nil) {
        guard !songs.isEmpty else { return }
        originalOrder = songs
        if shuffleEnabled {
            var shuffled = songs.shuffled()
            if let song, let i = shuffled.firstIndex(of: song) { shuffled.swapAt(0, i) }
            queue = shuffled
            index = 0
        } else {
            queue = songs
            index = song.flatMap { songs.firstIndex(of: $0) } ?? 0
        }
        consecutiveFailures = 0
        load(at: index, autoplay: true)
    }

    func setShuffle(_ on: Bool) {
        guard on != shuffleEnabled else { return }
        shuffleEnabled = on
        guard let current else { return }
        if on {
            queue = [current] + originalOrder.filter { $0 != current }.shuffled()
            index = 0
        } else {
            queue = originalOrder
            index = originalOrder.firstIndex(of: current) ?? 0
        }
    }

    func togglePlayPause() {
        if player.currentItem == nil {
            guard !queue.isEmpty else { return }
            load(at: index, autoplay: true)
        } else if player.timeControlStatus == .paused {
            resume()
        } else {
            pause()
        }
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        guard !queue.isEmpty else { return }
        var n = index + 1
        if n >= queue.count {
            // Loop the folder forever, reshuffling each pass.
            if shuffleEnabled { queue.shuffle() }
            n = 0
        }
        load(at: n, autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if elapsed > 3 {
            seek(to: 0)
        } else {
            load(at: index > 0 ? index - 1 : queue.count - 1, autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
        updateNowPlaying()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        originalOrder = []
        current = nil
        elapsed = 0
        duration = 0
        artwork = nil
        preparedArtwork = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Loading

    private func load(at i: Int, autoplay: Bool, transcoded: Bool = false) {
        guard queue.indices.contains(i) else { return }
        let localFile = transcoded ? nil : audioCache.localFile(for: queue[i].id)
        let url = localFile ?? (transcoded ? client.transcodedStreamURL(for: queue[i]) : client.directStreamURL(for: queue[i]))
        guard let url else { return }
        usingTranscode = transcoded
        index = i
        let song = queue[i]
        current = song
        elapsed = 0
        duration = song.duration ?? 0

        loader?.cancel()
        loader = nil
        playingLocalFile = localFile != nil
        loaded = playingLocalFile ? 1 : 0
        let asset: AVURLAsset
        if localFile != nil {
            asset = AVURLAsset(url: url)
        } else if cacheAudio && !transcoded {
            // Download the file once and play it as it arrives; it's saved to the device when complete.
            let songId = song.id
            let cache = audioCache
            let newLoader = DownloadingLoader(remoteURL: url, headers: client.streamHeaders) { data, mimeType in
                Task { @MainActor in cache.save(data, songId: songId, mimeType: mimeType) }
            }
            loader = newLoader
            asset = newLoader.makeAsset()
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.streamHeaders])
        }
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            let error = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, error: error) }
        }
        player.replaceCurrentItem(with: item)

        // Get the cover first, then announce the track and start playing, so the car receives
        // the title and cover together (many head units read the cover only once per track).
        loadArtwork(for: song, thenPlay: autoplay)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?) {
        switch status {
        case .readyToPlay:
            consecutiveFailures = 0
            cacheCurrentAndNext()
        case .failed:
            lastFailure = error
            if !usingTranscode {
                // The original file isn't playable on iOS; ask the server to transcode it.
                load(at: index, autoplay: true, transcoded: true)
            } else {
                skipAfterFailure()
            }
        default:
            break
        }
    }

    /// Pre-loads the next song in the queue so it starts instantly. (The playing song saves itself as it downloads.)
    private func cacheCurrentAndNext() {
        guard queue.count > 1 else { return }
        let nextSong = queue[(index + 1) % queue.count]
        // Pre-load the next cover so it's ready the instant the track changes (for car stereos).
        let nextCover = client.imageURLs(for: nextSong, size: 600)
        let nextFallback = client.imageURLs(for: nextSong, size: 150)
        if preparedArtwork[nextSong.id] == nil {
            Task { [weak self] in
                var image = await ImageCache.shared.image(for: nextCover)
                if image == nil { image = await ImageCache.shared.image(for: nextFallback) }
                guard let image, let self else { return }
                let art = await Task.detached { Self.makeArtwork(image) }.value
                self.preparedArtwork[nextSong.id] = art
            }
        }
        guard cacheAudio else { return }
        guard let url = client.directStreamURL(for: nextSong) else { return }
        audioCache.store(songId: nextSong.id, from: url, headers: client.streamHeaders)
    }

    private func skipAfterFailure() {
        consecutiveFailures += 1
        // Stop after 3 failures in a row (e.g. server unreachable or stream rejected) and say why.
        guard consecutiveFailures < min(3, queue.count) else {
            player.pause()
            errorMessage = "Couldn't play songs from the server: \(lastFailure ?? "unknown error")"
            return
        }
        next()
    }

    private func loadArtwork(for song: JFItem, thenPlay: Bool) {
        artworkTask?.cancel()
        // Only the playing song's and the next song's artwork need to stay around.
        preparedArtwork = preparedArtwork.filter { $0.key == song.id || $0.key == nextSongId }
        let urls = client.imageURLs(for: song, size: 600)
        // Smaller list thumbnails are often already on disk, which helps when offline.
        let fallbackURLs = client.imageURLs(for: song, size: 150)
        // The next song's cover is pre-loaded, so it's usually ready right away.
        if let prepared = preparedArtwork[song.id] {
            artwork = prepared
            updateNowPlaying()
            if thenPlay { resume() }
            return
        }
        if let cached = ImageCache.shared.memoryImage(for: urls) {
            artwork = Self.makeArtwork(cached)
            preparedArtwork[song.id] = artwork
            updateNowPlaying()
            if thenPlay { resume() }
            return
        }
        artwork = nil
        // Between songs nothing is playing, so with the screen off iOS could suspend the app mid-download.
        // Ask for a little background time until the cover is in.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "cover")
        artworkTask = Task { [weak self] in
            defer { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) } }
            // One download, shared by the 3 s wait and the rest: a slow connection (common with the
            // screen off) no longer gets cut off at 3 s and pushed back to a retry 10 s later.
            let fetch = Task.detached { () -> UIImage? in
                if let image = await ImageCache.shared.image(for: urls) { return image }
                return await ImageCache.shared.image(for: fallbackURLs)
            }
            let first = await Self.waitForCover(fetch, timeout: 3)
            guard !Task.isCancelled, let self, self.current?.id == song.id else { return }
            if let first { self.setArtwork(first, for: song) }
            self.updateNowPlaying()
            if thenPlay { self.resume() }
            guard first == nil else { return }

            // Not there within 3 s: keep waiting for the same download, then show it as soon as it lands.
            var image = await fetch.value
            // If the connection is down, keep retrying (10 s, 20 s, 40 s … up to 2 min apart) while this song plays.
            var delay: UInt64 = 10
            while image == nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 120)
                image = await ImageCache.shared.image(for: urls)
                if image == nil { image = await ImageCache.shared.image(for: fallbackURLs) }
            }
            guard let image, !Task.isCancelled, self.current?.id == song.id else { return }
            self.setArtwork(image, for: song)
            self.updateNowPlaying()
        }
    }

    private var nextSongId: String? {
        guard queue.count > 1 else { return nil }
        return queue[(index + 1) % queue.count].id
    }

    private func setArtwork(_ image: UIImage, for song: JFItem) {
        let art = Self.makeArtwork(image)
        artwork = art
        preparedArtwork[song.id] = art
    }

    /// The download's result, or nil if it isn't done within `timeout` seconds (the download keeps going).
    private nonisolated static func waitForCover(_ fetch: Task<UIImage?, Never>, timeout: Double) async -> UIImage? {
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { await fetch.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Lock screen / CarPlay / Bluetooth artwork: the cover centre-cropped to a 600 px square, drawn once.
    /// The system calls the handler on a background thread, so it only hands back the finished image
    /// (as the first builds did, when car covers worked) and isn't tied to the main actor.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        let square = squareImage(image, side: 600)
        return MPMediaItemArtwork(boundsSize: square.size) { _ in square }
    }

    private nonisolated static func squareImage(_ image: UIImage, side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let size = image.size
            let scale = max(side / max(size.width, 1), side / max(size.height, 1))
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
    }

    // MARK: Observation

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { _ = self?.tick(time) }
        }

        rateObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.updateNowPlaying()
            }
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.next()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.lastFailure = error
                self.skipAfterFailure()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended,
                  let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            else { return }
            MainActor.assumeIsolated { _ = self?.resume() }
        })
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { elapsed = seconds }
        updateLoaded()
        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0, abs(itemDuration - duration) > 0.5 {
            duration = itemDuration
            updateNowPlaying()
        }
    }

    private func updateLoaded() {
        let value: Double
        if playingLocalFile {
            value = 1
        } else if let loader {
            value = loader.progress
        } else if let item = player.currentItem, duration > 0 {
            // Streaming without saving: use what AVPlayer has buffered ahead.
            let end = item.loadedTimeRanges.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }.max() ?? 0
            value = min(1, max(0, end / duration))
        } else {
            value = 0
        }
        if abs(value - loaded) > 0.002 { loaded = value }
    }

    // MARK: System integration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { _ = self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.name,
            MPMediaItemPropertyArtist: current.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = current.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
