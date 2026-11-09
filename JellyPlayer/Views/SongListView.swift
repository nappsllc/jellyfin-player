import SwiftUI

struct SongListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer
    @State private var expanded = true
    @State private var lastOffset: CGFloat = 0
    /// List offset when the big player was last opened.
    @State private var expandedAt: CGFloat = 0
    @State private var query = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone held sideways: big player on the left, list on the right.
    private var isLandscape: Bool { verticalSizeClass == .compact && player.current != nil }

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

    private static let scrollSpace = "songScroll"
    /// Scrolling the list this far down shrinks the big player to the mini bar.
    private static let collapseDistance: CGFloat = 40

    var body: some View {
        Group {
            if isLandscape {
                landscapeLayout
            } else {
                VStack(spacing: 0) {
                    if showSearch {
                        searchField
                    }
                    playerArea
                    songList
                }
            }
        }
        // Sideways the navigation bar's title and buttons move into the list column, so the cover can use the full height.
        .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
        .onChange(of: player.current == nil) { _, stopped in
            if stopped { expanded = true; expandedAt = lastOffset }
        }
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

    /// iPhone held sideways: the cover with its controls fills the screen height on the left; title, playback bar,
    /// the folder name with search and settings, and the list fill the rest of the width.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            // Same margin on every side as the portrait layout's side margins.
            let margin: CGFloat = 24
            let scrubberHeight: CGFloat = 46
            let spacing: CGFloat = 12
            let side = max(min(geo.size.height - 2 * margin - scrubberHeight - spacing, geo.size.width * 0.5), 120)
            HStack(spacing: 0) {
                // Cover with the playback bar under it.
                VStack(spacing: spacing) {
                    NowPlayingCover(side: side)
                    PlaybackScrubber()
                        .frame(width: side)
                }
                .padding(.vertical, margin)
                .padding(.trailing, margin)
                // Keep the cover clear of the Dynamic Island when it's on the left.
                .padding(.leading, max(margin, insets.leading))
                .frame(maxHeight: .infinity, alignment: .center)

                VStack(spacing: 0) {
                    landscapeTopBar
                    if showSearch {
                        searchField
                    }
                    NowPlayingInfo(alignment: .leading, showsScrubber: false)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    Divider()
                    songList
                        .contentMargins(.bottom, insets.bottom, for: .scrollContent)
                }
                // Rows already have 16 pt inside, so this ends them `margin` from the screen edge.
                // …and the list clear of it when it's on the right.
                .padding(.trailing, max(margin, insets.trailing) - 16)
                .padding(.top, margin - 10)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
    }

    private var landscapeTopBar: some View {
        HStack(spacing: 20) {
            Text(model.folder?.name ?? "JellyPlayer")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if showSearch { closeSearch() } else { showSearch = true }
                }
                if showSearch { DispatchQueue.main.async { searchFocused = true } }
            } label: {
                Image(systemName: showSearch ? "xmark" : "magnifyingglass")
            }
            .accessibilityLabel(showSearch ? "Close search" : "Search")
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        .font(.title3)
        .padding(.leading)
        // Extra room on the right so the gear stays clear of the screen's rounded corner.
        .padding(.trailing, 28)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// The player sits above the list and never scrolls with it. Big tile, or the mini bar
    /// once the list is scrolled or while searching. Tapping the mini bar opens the big tile
    /// again without moving the list.
    @ViewBuilder
    private var playerArea: some View {
        if player.current != nil {
            if expanded && !isSearching {
                NowPlayingHeader()
                    .frame(maxWidth: .infinity)
                    // Full-size cover first; the list gets the space that's left.
                    .layoutPriority(1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                NowPlayingBar {
                    searchFocused = false
                    if isSearching { closeSearch() }
                    expandedAt = lastOffset
                    withAnimation(.easeInOut(duration: 0.25)) { expanded = true }
                }
            }
            Divider()
        } else {
            startButtons
        }
    }

    private var songList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ListOffsetKey.self,
                                value: -geo.frame(in: .named(Self.scrollSpace)).minY
                            )
                        }
                    )

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
        .scrollDismissesKeyboard(.immediately)
        .modifier(ScrollOffsetReader { listScrolled(to: $0) })
        .refreshable { await model.reload() }
    }

    private func listScrolled(to offset: CGFloat) {
        lastOffset = offset
        guard expanded else { return }
        // Shrink once the list has moved down a bit from where it was when the big player opened.
        // Measuring from that point (not from the top) keeps the list where you left it.
        expandedAt = min(expandedAt, max(offset, 0))
        if offset > expandedAt + Self.collapseDistance {
            withAnimation(.easeInOut(duration: 0.25)) { expanded = false }
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
    }

    private func closeSearch() {
        query = ""
        searchFocused = false
        showSearch = false
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

/// Reports how far the list is scrolled. Uses the scroll view's own geometry on iOS 18+,
/// where marker-view preferences inside a ScrollView aren't reliably delivered while scrolling.
private struct ScrollOffsetReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                onChange(offset)
            }
        } else {
            content.onPreferenceChange(ListOffsetKey.self) { onChange($0) }
        }
    }
}

private struct ListOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

    init(urls: [URL], placeholder: String = "music.note", placeholderSize: CGFloat? = nil) {
        self.urls = urls
        self.placeholder = placeholder
        self.placeholderSize = placeholderSize
        // Start with an already-loaded cover so it appears in the same frame (and animation) as the
        // rest of the view, instead of popping in a moment later.
        _image = State(initialValue: ImageCache.shared.memoryImage(for: urls))
    }

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
