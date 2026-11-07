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
    /// Set when playback fails, so the UI can show why.
    @Published var errorMessage: String?

    private(set) var shuffleEnabled = false
    private var queue: [JFItem] = []
    private var originalOrder: [JFItem] = []
    private var index = 0
    private var consecutiveFailures = 0
    private var lastFailure: String?
    private var usingTranscode = false

    private let player = AVPlayer()
    private let client: JellyfinClient
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Loading

    private func load(at i: Int, autoplay: Bool, transcoded: Bool = false) {
        guard queue.indices.contains(i) else { return }
        let url = transcoded ? client.transcodedStreamURL(for: queue[i]) : client.directStreamURL(for: queue[i])
        guard let url else { return }
        usingTranscode = transcoded
        index = i
        let song = queue[i]
        current = song
        elapsed = 0
        duration = song.duration ?? 0

        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.streamHeaders])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            let error = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, error: error) }
        }
        player.replaceCurrentItem(with: item)
        if autoplay { resume() }

        artwork = nil
        updateNowPlaying()
        loadArtwork(for: song)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?) {
        switch status {
        case .readyToPlay:
            consecutiveFailures = 0
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

    private func loadArtwork(for song: JFItem) {
        artworkTask?.cancel()
        let urls = client.imageURLs(for: song, size: 600)
        artworkTask = Task { [weak self] in
            var found: UIImage?
            for url in urls {
                if let result = try? await URLSession.shared.data(from: url),
                   (result.1 as? HTTPURLResponse)?.statusCode == 200,
                   let image = UIImage(data: result.0) {
                    found = image
                    break
                }
            }
            guard let image = found, !Task.isCancelled else { return }
            guard let self, self.current?.id == song.id else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
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
        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0, abs(itemDuration - duration) > 0.5 {
            duration = itemDuration
            updateNowPlaying()
        }
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
