import SwiftUI

/// Browse Jellyfin libraries and folders and pick the one to play from.
struct FolderPickerView: View {
    @EnvironmentObject private var model: AppModel
    let parent: JFItem?

    @State private var folders: [JFItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        List {
            if let parent {
                Section {
                    Button {
                        model.selectFolder(parent)
                    } label: {
                        Label("Play from “\(parent.name)”",
                              systemImage: model.folder?.id == parent.id ? "checkmark.circle.fill" : "circle")
                    }
                }
            }

            Section(parent == nil ? "Libraries" : "Subfolders") {
                if isLoading {
                    ProgressView()
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red)
                } else if folders.isEmpty {
                    Text("No subfolders").foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    NavigationLink {
                        FolderPickerView(parent: folder)
                    } label: {
                        HStack(spacing: 12) {
                            CoverArt(urls: model.client.imageURLs(for: folder, size: 100), size: 36, placeholder: "folder")
                            Text(folder.name).lineLimit(1)
                            Spacer()
                            if model.folder?.id == folder.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(parent?.name ?? "Choose folder")
        .task { await load() }
    }

    private func load() async {
        guard folders.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let parent {
                folders = try await model.client.folders(in: parent.id)
            } else {
                folders = try await model.client.libraries()
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
