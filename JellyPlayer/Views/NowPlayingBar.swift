import SwiftUI

/// Large "now playing" tile shown above the song list: cover, title, scrubber and controls.
struct NowPlayingHeader: View {
    @EnvironmentObject private var player: AudioPlayer
    @State private var availableWidth: CGFloat = 320

    private var coverSide: CGFloat { max(min(availableWidth, 320), 120) }

    var body: some View {
        if player.current != nil {
            VStack(spacing: 16) {
                NowPlayingCover(side: coverSide)
                NowPlayingInfo(alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }
}

/// Title, artist and the playback bar for the current song.
struct NowPlayingInfo: View {
    @EnvironmentObject private var player: AudioPlayer
    var alignment: HorizontalAlignment = .center
    var showsScrubber = true

    var body: some View {
        if let song = player.current {
            VStack(alignment: alignment, spacing: 12) {
                VStack(alignment: alignment, spacing: 4) {
                    MarqueeText(text: song.name, font: .title3.bold(), alignment: alignment)
                    MarqueeText(text: song.subtitle, font: .subheadline, alignment: alignment)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)

                if showsScrubber {
                    PlaybackScrubber()
                }
            }
        }
    }
}

/// One line of text that, when too long to fit, slides slowly to show its end,
/// pauses, then slides back, over and over. Short text just sits still.
struct MarqueeText: View {
    let text: String
    let font: Font
    var alignment: HorizontalAlignment = .center

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(textWidth - boxWidth, 0) }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay(alignment: overflow > 0 ? .leading : Alignment(horizontal: alignment, vertical: .center)) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear.onAppear { textWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in textWidth = w }
                    })
                    .offset(x: offset)
            }
            .background(GeometryReader { g in
                Color.clear.onAppear { boxWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in boxWidth = w }
            })
            .clipped()
            // Soft fade at the edges while sliding so cut-off letters don't look chopped.
            .mask {
                if overflow > 0 {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.04),
                                           .init(color: .black, location: 0.96),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                } else {
                    Rectangle()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(text)
            .task(id: "\(text)|\(overflow)") { await slide() }
    }

    private func slide() async {
        offset = 0
        guard overflow > 0 else { return }
        let duration = max(Double(overflow) / 30, 1)   // ~30 pt per second
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            withAnimation(.linear(duration: duration)) { offset = -overflow }
            try? await Task.sleep(for: .seconds(duration + 1.5))
            if Task.isCancelled { return }
            withAnimation(.linear(duration: duration)) { offset = 0 }
            try? await Task.sleep(for: .seconds(duration))
        }
    }
}

/// The square cover with previous / play-pause / next drawn over it, sized to `side`.
/// The controls scale with the cover so they always fit inside it.
struct NowPlayingCover: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer
    let side: CGFloat

    var body: some View {
        if let song = player.current {
            Artwork(urls: model.client.imageURLs(for: song, size: 600))
                .overlay { controls }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // Fixed square size so nothing around it can squeeze the cover.
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        }
    }

    /// Sizes for a 320 pt cover, scaled to the actual one.
    private var scale: CGFloat { min(max(side / 320, 0.55), 1.3) }

    /// Previous / play-pause / next on a soft dark scrim, with shuffle in the corner.
    private var controls: some View {
        ZStack {
            Color.black.opacity(0.28)

            HStack(spacing: 44 * scale) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 30 * scale))
                }
                .accessibilityLabel("Previous")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 52 * scale))
                        .frame(width: 64 * scale, height: 64 * scale)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 30 * scale))
                }
                .accessibilityLabel("Next")
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.shuffle.toggle() } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 18 * scale, weight: .semibold))
                            .padding(10 * scale)
                            .background(model.shuffle ? Color.accentColor : Color.black.opacity(0.35), in: Circle())
                    }
                    .accessibilityLabel(model.shuffle ? "Shuffle on" : "Shuffle off")
                }
            }
            .padding(12 * scale)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 4)
        .buttonStyle(.plain)
    }
}

/// Compact one-line player shown above the list once it is scrolled or while searching. Tap it to expand again.
struct NowPlayingBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer
    var onTap: () -> Void = {}

    var body: some View {
        if let song = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverArt(urls: model.client.imageURLs(for: song, size: 600), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.name).font(.headline).lineLimit(1)
                        Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 20) {
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 32)
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").font(.title3)
                        }
                        .accessibilityLabel("Next")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                GeometryReader { geo in
                    let played = player.duration > 0 ? min(player.elapsed / player.duration, 1) : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.2))
                        Rectangle().fill(Color.accentColor.opacity(0.3))
                            .frame(width: geo.size.width * CGFloat(max(player.loaded, played)))
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(played))
                    }
                }
                .frame(height: 3)
            }
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows the large player")
        }
    }
}

/// Seek slider with elapsed / total time.
struct PlaybackScrubber: View {
    @EnvironmentObject private var player: AudioPlayer
    @State private var scrubPosition: Double?

    private var total: Double { max(player.duration, 1) }
    private var position: Double { min(scrubPosition ?? player.elapsed, total) }

    var body: some View {
        VStack(spacing: 6) {
            ProgressTrack(played: position / total, loaded: player.loaded, active: scrubPosition != nil)
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0 else { return }
                            scrubPosition = fraction(at: value.location.x) * total
                        }
                        .onEnded { value in
                            guard player.duration > 0 else { return }
                            player.seek(to: fraction(at: value.location.x) * total)
                            scrubPosition = nil
                        }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatTime(position)) of \(formatTime(player.duration))")
                .accessibilityAdjustableAction { direction in
                    let step: Double = direction == .increment ? 10 : -10
                    player.seek(to: min(max(player.elapsed + step, 0), total))
                }
            HStack {
                Text(formatTime(position))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    @State private var width: CGFloat = 1

    private func fraction(at x: CGFloat) -> Double {
        Double(min(max(x / max(width, 1), 0), 1))
    }
}

/// YouTube-style bar: grey track, a soft purple part for what's already downloaded, solid purple for what's played.
struct ProgressTrack: View {
    let played: Double
    let loaded: Double
    var active = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barHeight: CGFloat = active ? 8 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor.opacity(0.3))
                    .frame(width: w * CGFloat(min(max(loaded, played), 1)))
                Capsule().fill(Color.accentColor)
                    .frame(width: w * CGFloat(min(max(played, 0), 1)))
            }
            .frame(height: barHeight)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: active ? 18 : 12, height: active ? 18 : 12)
                    .offset(x: w * CGFloat(min(max(played, 0), 1)) - (active ? 9 : 6))
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: active)
        }
    }
}

/// Square cover that scales to the width it is given.
struct Artwork: View {
    let urls: [URL]

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { FallbackImage(urls: urls, placeholderSize: 64) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
