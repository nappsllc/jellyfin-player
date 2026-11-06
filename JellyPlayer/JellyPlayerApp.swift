import SwiftUI

@main
struct JellyPlayerApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Cache cover art so scrolling the list doesn't re-download it.
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 300_000_000)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.player)
                .task { await model.start() }
        }
    }
}
