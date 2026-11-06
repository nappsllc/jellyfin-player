import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        NavigationStack {
            Group {
                if model.session == nil || model.folder == nil {
                    ContentUnavailableView {
                        Label("Set up JellyPlayer", systemImage: "music.note.house")
                    } description: {
                        Text("Sign in to your Jellyfin server and choose a music folder.")
                    } actions: {
                        Button("Open Settings") { model.showSettings = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if model.isLoading && model.songs.isEmpty {
                    ProgressView("Loading songs…")
                } else if model.songs.isEmpty {
                    ContentUnavailableView("No songs", systemImage: "music.note",
                                           description: Text("This folder doesn't contain any audio files."))
                } else {
                    SongListView()
                }
            }
            .navigationTitle(model.folder?.name ?? "JellyPlayer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model)
                .environmentObject(player)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil || player.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil; player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? player.errorMessage ?? "")
        }
    }
}
