import Foundation

/// App state: sign-in, settings, the chosen folder and its songs.
@MainActor
final class AppModel: ObservableObject {
    private enum Keys {
        static let autoPlay = "autoPlay"
        static let shuffle = "shuffle"
        static let folder = "folder"
        static let lastServer = "lastServer"
    }

    let client: JellyfinClient
    let player: AudioPlayer
    private let defaults = UserDefaults.standard

    @Published private(set) var session: JellyfinSession? = nil {
        didSet { client.session = session }
    }
    @Published private(set) var folder: FolderSelection? = nil {
        didSet {
            if let folder, let data = try? JSONEncoder().encode(folder) {
                defaults.set(data, forKey: Keys.folder)
            } else {
                defaults.removeObject(forKey: Keys.folder)
            }
        }
    }
    @Published private(set) var songs: [JFItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var showSettings = false

    @Published var autoPlay: Bool {
        didSet { defaults.set(autoPlay, forKey: Keys.autoPlay) }
    }
    @Published var shuffle: Bool {
        didSet {
            defaults.set(shuffle, forKey: Keys.shuffle)
            player.setShuffle(shuffle)
        }
    }

    var lastServer: String { defaults.string(forKey: Keys.lastServer) ?? "" }

    private var started = false

    init() {
        let defaults = UserDefaults.standard
        let client = JellyfinClient()
        self.client = client
        player = AudioPlayer(client: client)
        autoPlay = defaults.object(forKey: Keys.autoPlay) as? Bool ?? true
        shuffle = defaults.bool(forKey: Keys.shuffle)
        if let data = defaults.data(forKey: Keys.folder) {
            folder = try? JSONDecoder().decode(FolderSelection.self, from: data)
        }
        let savedSession = SessionStore.load()
        session = savedSession
        client.session = savedSession
        player.setShuffle(shuffle)
    }

    /// Called once when the app opens: load the folder and auto-play if that setting is on.
    func start() async {
        guard !started else { return }
        started = true
        guard session != nil, folder != nil else {
            showSettings = true
            return
        }
        await reload()
        if autoPlay { player.play(songs: songs) }
    }

    func reload() async {
        guard let folder else { songs = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            songs = try await client.songs(in: folder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn(server: String, username: String, password: String) async throws {
        let newSession = try await client.authenticate(server: server, username: username, password: password)
        defaults.set(server, forKey: Keys.lastServer)
        SessionStore.save(newSession)
        session = newSession
    }

    func signOut() {
        player.stop()
        SessionStore.clear()
        session = nil
        folder = nil
        songs = []
    }

    func selectFolder(_ item: JFItem) {
        folder = FolderSelection(id: item.id, name: item.name)
        Task {
            await reload()
            if autoPlay, player.current == nil { player.play(songs: songs) }
        }
    }
}
