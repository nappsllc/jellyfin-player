# JellyPlayer

A small native iOS (SwiftUI) audio player for Jellyfin. Pick one folder on your server, and the app shows every song in it (title, artist, album, cover art) and plays it. It can start playing automatically when it opens, and can shuffle.

## Features

- Sign in to any Jellyfin server (local `http://` or remote `https://`). The token is stored in the Keychain.
- Browse libraries and folders and pick the one to play from. Songs in subfolders are included.
- Song list with cover art, title, artist and album. Tap a song to play from there.
- Settings: **Auto-play on launch** (on by default) and **Shuffle**.
- Mini player with previous / play-pause / next and a scrubber.
- Keeps playing in the background, with lock screen, Control Center and headphone controls.
- Plays the folder on a loop. Formats iOS can't decode are transcoded to AAC by the server automatically.

## Run it

Needs a Mac with Xcode 16 or newer and iOS 17+ on the device.

1. Open `JellyPlayer.xcodeproj`.
2. Select the **JellyPlayer** target → *Signing & Capabilities* → choose your Team (a free Apple ID works for your own phone).
3. Pick your iPhone or a simulator and press Run.
4. On first launch Settings opens: enter the server URL (e.g. `http://192.168.1.10:8096`), username and password, then choose a folder.

If the project ever gets out of shape, `brew install xcodegen && xcodegen` regenerates it from `project.yml`.

## Code map

| File | What it does |
| --- | --- |
| `JellyfinClient.swift` | Jellyfin REST calls: sign in, list libraries/folders/songs, stream and cover URLs |
| `AudioPlayer.swift` | AVPlayer queue, shuffle, background audio, lock screen controls |
| `AppModel.swift` | Settings, selected folder, auto-play on launch |
| `SessionStore.swift` | Keychain storage for the login |
| `Views/` | Song list, mini player, settings, folder picker |
