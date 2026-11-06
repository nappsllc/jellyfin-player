import SwiftUI

/// Large "now playing" tile shown at the top of the song list: cover, title, scrubber and controls.
struct NowPlayingHeader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        if let song = player.current {
            VStack(spacing: 16) {
                Artwork(url: model.client.imageURL(for: song, size: 800))
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

                HStack {
                    Button { model.shuffle.toggle() } label: {
                        Image(systemName: "shuffle")
                            .font(.title3)
                            .foregroundStyle(model.shuffle ? Color.accentColor : Color.secondary)
                    }
                    .accessibilityLabel(model.shuffle ? "Shuffle on" : "Shuffle off")
                    Spacer()
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill").font(.title)
                    }
                    .accessibilityLabel("Previous")
                    Spacer()
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Spacer()
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title)
                    }
                    .accessibilityLabel("Next")
                    Spacer()
                    // Balances the shuffle button so the play button stays centred.
                    Image(systemName: "shuffle").font(.title3).hidden()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
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
