import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var signInError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Jellyfin server") {
                    if let session = model.session {
                        LabeledContent("Server", value: session.serverURL.absoluteString)
                        LabeledContent("User", value: session.userName)
                        Button("Sign out", role: .destructive) { model.signOut() }
                    } else {
                        TextField("Server URL", text: $server, prompt: Text("http://192.168.1.10:8096"))
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        if let signInError {
                            Text(signInError).font(.footnote).foregroundStyle(.red)
                        }
                        Button {
                            Task { await signIn() }
                        } label: {
                            if isSigningIn { ProgressView() } else { Text("Sign in") }
                        }
                        .disabled(server.isEmpty || username.isEmpty || isSigningIn)
                    }
                }

                if model.session != nil {
                    Section {
                        NavigationLink {
                            FolderPickerView(parent: nil)
                        } label: {
                            LabeledContent("Folder", value: model.folder?.name ?? "Choose…")
                        }
                    } header: {
                        Text("Music folder")
                    } footer: {
                        Text("Every song inside this folder, including subfolders, is shown and played.")
                    }
                }

                Section {
                    Toggle("Auto-play on launch", isOn: $model.autoPlay)
                    Toggle("Shuffle", isOn: $model.shuffle)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("With auto-play on, music starts as soon as the app opens.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if server.isEmpty { server = model.lastServer }
        }
    }

    private func signIn() async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            try await model.signIn(server: server, username: username, password: password)
            password = ""
        } catch {
            signInError = error.localizedDescription
        }
    }
}
