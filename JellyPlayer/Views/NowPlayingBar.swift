import SwiftUI

/// Large "now playing" tile shown at the top of the song list: cover, title, scrubber and controls.
struct NowPlayingHeader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        if let song = player.current {
            VStack(spacing: 16) {
                Artwork(url: model.client.imageURL(for: song, size: 800))
                    .overlay { coverControls }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: 320)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(song.name)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(song.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }

                PlaybackScrubber()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    /// Previous / play-pause / next drawn over the cover on a soft dark scrim, with shuffle in the corner.
    private var coverControls: some View {
        ZStack {
            Color.black.opacity(0.28)

            HStack(spacing: 44) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 30))
                }
                .accessibilityLabel("Previous")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 52))
                        .frame(width: 64, height: 64)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 30))
                }
                .accessibilityLabel("Next")
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.shuffle.toggle() } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 18, weight: .semibold))
                            .padding(10)
                            .background(model.shuffle ? Color.accentColor : Color.black.opacity(0.35), in: Circle())
                    }
                    .accessibilityLabel(model.shuffle ? "Shuffle on" : "Shuffle off")
                }
            }
            .padding(12)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 4)
        .buttonStyle(.plain)
    }
}

/// Compact one-line player pinned to the top once the big tile scrolls away. Tap it to expand again.
struct NowPlayingBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer
    var onTap: () -> Void = {}

    var body: some View {
        if let song = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverArt(url: model.client.imageURL(for: song, size: 200), size: 44)
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

                ProgressView(value: player.duration > 0 ? min(player.elapsed / player.duration, 1) : 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
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

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { min(scrubPosition ?? player.elapsed, max(player.duration, 1)) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let position = scrubPosition {
                        player.seek(to: position)
                        scrubPosition = nil
                    }
                }
            )
            .disabled(player.duration <= 0)
            HStack {
                Text(formatTime(scrubPosition ?? player.elapsed))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

/// Square cover that scales to the width it is given.
struct Artwork: View {
    let url: URL?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
