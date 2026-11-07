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

## Install and auto-update with SideStore (recommended)

Every push to `main` publishes a GitHub release with `JellyPlayer.ipa` and a SideStore/AltStore source feed.

1. Install SideStore on the iPhone, e.g. with [iloader](https://github.com/nab138/iloader) ("SideStore (Stable)"), and install LocalDevVPN from the App Store.
2. In SideStore → **Sources** → **+**, add:
   `https://github.com/nappsllc/jellyfin-player/releases/latest/download/apps.json`
3. Install JellyPlayer from that source. SideStore refreshes it every 7 days on the phone and offers new versions as updates.

## Install from Windows (no Mac, no paid account)

Every push to `main` builds an unsigned `JellyPlayer.ipa` on GitHub's Mac runners.

1. Open the repo's **Actions** tab → latest **Build IPA** run → download the **JellyPlayer-ipa** artifact and unzip it.
2. Install it with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io), signing in with your free Apple ID. AltStore can refresh it automatically.
3. On the iPhone: turn on **Developer Mode** (Settings → Privacy & Security), and trust your Apple ID under Settings → General → VPN & Device Management.

With a free Apple ID the app expires after 7 days and has to be re-signed (AltStore does this for you while your PC is reachable).

If the project ever gets out of shape, `brew install xcodegen && xcodegen` regenerates it from `project.yml`.

## Code map

| File | What it does |
| --- | --- |
| `JellyfinClient.swift` | Jellyfin REST calls: sign in, list libraries/folders/songs, stream and cover URLs |
| `AudioPlayer.swift` | AVPlayer queue, shuffle, background audio, lock screen controls |
| `AppModel.swift` | Settings, selected folder, auto-play on launch |
| `SessionStore.swift` | Keychain storage for the login |
| `Views/` | Song list, mini player, settings, folder picker |
