import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var cacheSize: Int64 = 0

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
                    Toggle("Play saved songs only", isOn: $model.offlineOnly)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("With auto-play on, music starts as soon as the app opens. Play saved songs only is for when there's no network for a long time: the list shows just the songs saved on this iPhone, and the server isn't contacted.")
                }

                Section {
                    Toggle("Save played songs on device", isOn: $model.cacheAudio)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Keep up to", value: Self.limitLabel(model.cacheLimitGB))
                        Slider(value: $model.cacheLimitGB, in: 0...100, step: 1) {
                            Text("Keep up to")
                        } minimumValueLabel: {
                            Text("0")
                        } maximumValueLabel: {
                            Text("100 GB")
                        } onEditingChanged: { editing in
                            // Trim only once the slider is let go, not while dragging past small values.
                            guard !editing else { return }
                            model.trimCache()
                            cacheSize = model.cacheSize()
                        }
                    }
                    LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("Clear cache", role: .destructive) {
                        model.clearCache()
                        cacheSize = model.cacheSize()
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Covers and played songs are kept on this iPhone so they load instantly and play offline. Once the limit is reached, the songs played longest ago are removed first.")
                }

                Section {
                    LabeledContent("Version", value: Self.appVersion)
                    NavigationLink("Cover log") { CoverLogView() }
                } footer: {
                    Text("The cover log records how each song's cover was loaded and sent to the lock screen and car. It stays on this iPhone unless you copy or share it.")
                }
            }
            .onAppear { cacheSize = model.cacheSize() }
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

    private static func limitLabel(_ gb: Double) -> String {
        gb <= 0 ? "Nothing" : gb < 1 ? "\(Int(gb * 1000)) MB" : "\(Int(gb.rounded())) GB"
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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


/// Shows the on-device cover log, newest at the bottom, with copy, share and clear.
struct CoverLogView: View {
    @State private var text = DiagLog.shared.text

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Nothing logged yet. Play a song first." : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .navigationTitle("Cover log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Copy") { UIPasteboard.general.string = text }
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
                Button("Clear", role: .destructive) {
                    DiagLog.shared.clear()
                    text = ""
                }
            }
        }
    }
}
