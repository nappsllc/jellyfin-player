import SwiftUI

struct SongListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        List {
            HStack(spacing: 12) {
                Button {
                    player.play(songs: model.songs)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.shuffle.toggle()
                } label: {
                    Label(model.shuffle ? "Shuffle on" : "Shuffle off", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(model.shuffle ? Color.accentColor : Color.secondary)
            }
            .controlSize(.large)
            .listRowSeparator(.hidden)

            Section {
                ForEach(model.songs) { song in
                    Button {
                        player.play(songs: model.songs, startAt: song)
                    } label: {
                        SongRow(song: song,
                                isCurrent: player.current?.id == song.id,
                                isPlaying: player.isPlaying)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(model.songs.count) songs")
            }
        }
        .listStyle(.plain)
        .refreshable { await model.reload() }
    }
}

struct SongRow: View {
    @EnvironmentObject private var model: AppModel
    let song: JFItem
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverArt(url: model.client.imageURL(for: song, size: 150), size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(song.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(Color.accentColor)
            } else if let duration = song.duration {
                Text(formatTime(duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct CoverArt: View {
    let url: URL?
    let size: CGFloat
    var placeholder = "music.note"

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: placeholder).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
    }
}
