import SwiftUI

struct SongListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer
    @State private var headerCollapsed = false
    @State private var query = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Songs matching every word of the search in the title, artist or album.
    private var visibleSongs: [JFItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return model.songs }
        return model.songs.filter { song in
            let haystack = "\(song.name) \(song.artistLine) \(song.album ?? "")"
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private static let headerID = "nowPlayingHeader"
    private static let scrollSpace = "songScroll"
    /// The big tile counts as scrolled away once less than this much of it is still visible.
    private static let collapseThreshold: CGFloat = 90

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isSearching {
                        EmptyView()
                    } else if player.current != nil {
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

                    Text(isSearching ? "\(visibleSongs.count) of \(model.songs.count) songs" : "\(model.songs.count) songs")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    LazyVStack(alignment: .leading, spacing: 0) {
                    if isSearching && visibleSongs.isEmpty {
                        Text("No songs match “\(query)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(visibleSongs) { song in
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
            // While scrolling, the mini player floats over the list (no jump when it appears).
            .overlay(alignment: .top) {
                if headerCollapsed && !isSearching && player.current != nil {
                    miniPlayer(proxy)
                }
            }
            // The search field and, while searching, the mini player take their own space at the top
            // so the first result isn't hidden under them.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if showSearch {
                        searchField
                    }
                    if isSearching && player.current != nil {
                        miniPlayer(proxy)
                    }
                }
            }
            .refreshable { await model.reload() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if showSearch { closeSearch() } else { showSearch = true }
                        }
                        if showSearch { DispatchQueue.main.async { searchFocused = true } }
                    } label: {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                    }
                    .accessibilityLabel(showSearch ? "Close search" : "Search")
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Title or artist", text: $query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func closeSearch() {
        query = ""
        searchFocused = false
        showSearch = false
    }

    private func miniPlayer(_ proxy: ScrollViewProxy) -> some View {
        NowPlayingBar {
            closeSearch()
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(Self.headerID, anchor: .top)
                }
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
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
