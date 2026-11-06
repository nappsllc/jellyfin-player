import SwiftUI

struct NowPlayingBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer
    @State private var scrubPosition: Double?

    var body: some View {
        if let song = player.current {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    CoverArt(url: model.client.imageURL(for: song, size: 200), size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.name).font(.headline).lineLimit(1)
                        Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 20) {
                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill")
                        }
                        .accessibilityLabel("Previous")
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .frame(width: 32)
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill")
                        }
                        .accessibilityLabel("Next")
                    }
                    .font(.title3)
                    .buttonStyle(.plain)
                }

                if player.duration > 0 {
                    Slider(
                        value: Binding(
                            get: { min(scrubPosition ?? player.elapsed, player.duration) },
                            set: { scrubPosition = $0 }
                        ),
                        in: 0...player.duration,
                        onEditingChanged: { editing in
                            if !editing, let position = scrubPosition {
                                player.seek(to: position)
                                scrubPosition = nil
                            }
                        }
                    )
                    HStack {
                        Text(formatTime(scrubPosition ?? player.elapsed))
                        Spacer()
                        Text(formatTime(player.duration))
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }
}
