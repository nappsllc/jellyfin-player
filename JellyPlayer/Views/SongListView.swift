import SwiftUI

struct SongListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer
    @State private var headerCollapsed = false

    private static let headerID = "nowPlayingHeader"
    private static let scrollSpace = "songScroll"
    /// The big tile counts as scrolled away once less than this much of it is still visible.
    private static let collapseThreshold: CGFloat = 90

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if player.current != nil {
                        NowPlayingHeader()
                            .frame(maxWidth: .infinity)
                            .id(Self.headerID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: HeaderBottomKey.self,
                                        value: geo.frame(in: .named(Self.scrollSpace)).maxY
                                    )
                                }
                            )
                        Divider()
                    } else {
                        startButtons
                    }

                    Text("\(model.songs.count) songs")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.songs) { song in
                        Button {
                            player.play(songs: model.songs, startAt: song)
                        } label: {
                            SongRow(song: song,
                                    isCurrent: player.current?.id == song.id,
                                    isPlaying: player.isPlaying)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 76)
                    }
                    }
                }
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(HeaderBottomKey.self) { bottom in
                let collapsed = bottom < Self.collapseThreshold
                if collapsed != headerCollapsed {
                    withAnimation(.easeInOut(duration: 0.2)) { headerCollapsed = collapsed }
                }
            }
            .onChange(of: player.current == nil) { _, stopped in
                if stopped { headerCollapsed = false }
            }
            .overlay(alignment: .top) {
                if headerCollapsed && player.current != nil {
                    NowPlayingBar {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(Self.headerID, anchor: .top)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .refreshable { await model.reload() }
        }
    }

    /// Shown when nothing is playing yet (e.g. auto-play is off).
    private var startButtons: some View {
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
        .padding()
    }
}

private struct HeaderBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

struct SongRow: View {
    @EnvironmentObject private var model: AppModel
    let song: JFItem
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverArt(urls: model.client.imageURLs(for: song, size: 150), size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(song.artistLine)
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
    let urls: [URL]
    let size: CGFloat
    var placeholder = "music.note"

    var body: some View {
        FallbackImage(urls: urls, placeholder: placeholder)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
    }
}

/// Tries each URL in turn until one has an image. Loads only when the view is on screen and caches on the device.
struct FallbackImage: View {
    let urls: [URL]
    var placeholder = "music.note"
    var placeholderSize: CGFloat? = nil
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: placeholder)
                    .font(placeholderSize.map { .system(size: $0) } ?? .body)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: urls) {
            if let cached = ImageCache.shared.memoryImage(for: urls) {
                image = cached
                return
            }
            image = nil
            // Retry while on screen, in case the connection dropped (10 s, 20 s, 40 s … up to 2 min apart).
            var delay: UInt64 = 10
            while !Task.isCancelled {
                if let loaded = await ImageCache.shared.image(for: urls) {
                    image = loaded
                    return
                }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 120)
            }
        }
    }
}
