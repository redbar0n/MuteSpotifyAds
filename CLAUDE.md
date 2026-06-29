# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MuteSpotifyAds is a native macOS menu-bar app (Swift/Cocoa) that automatically mutes ads in the Spotify desktop app. It is a community-maintained fork of the archived upstream `simonmeusel/MuteSpotifyAds`, now hosted at `MikeWLloyd/MuteSpotifyAds`. GPLv3 licensed.

This is a **macOS-only** project. It builds with Xcode and depends on macOS frameworks (Cocoa, FSEvents, AppleScript via `osascript`). It cannot be built or run on the current Windows host — builds, tests, and releases all require a Mac with Xcode.

## Build & release

```bash
# Build (Release) and produce release artifacts in ./dist
./scripts/package_release.sh

# Plain build via Xcode
xcodebuild -project MuteSpotifyAds.xcodeproj -scheme MuteSpotifyAds -configuration Release build
```

`package_release.sh` does a clean Release build into `build-release/`, then produces three artifacts in `dist/`: `MuteSpotifyAds.app.tar.gz` (consumed by the Homebrew cask), `MuteSpotifyAds-source.tar.gz` (GPLv3 source archive via `git archive`), and `checksums.txt`. Override `SCHEME`, `CONFIGURATION`, `DERIVED_DATA_PATH`, or `OUTPUT_DIR` via env vars.

There is no test target, no linter, and no package manager — it's a single Xcode project with no third-party dependencies.

### Release process

The Homebrew cask (`Casks/mutespotifyads.rb`) pulls from the GitHub *latest release* asset `MuteSpotifyAds.app.tar.gz`, so every release **must** publish an asset with exactly that name or Homebrew installs break. Bump `CFBundleShortVersionString` in `MuteSpotifyAds/Info.plist`, run the package script, create a GitHub release tag, and upload the `dist/` assets.

## Architecture

The whole app is three Swift files plus a XIB-defined menu:

- **`AppDelegate.swift`** — owns the `NSStatusItem` (menu-bar icon) and the menu wired up in `Base.lproj/MainMenu.xib`. Reads/writes all user preferences via `UserDefaults` (keys are the `*Key` string constants at the top of the class). Each menu toggle (`toggleEndlessPrivateSession`, `toggleRestartToSkipAds`, `toggleNotifications`, `toggleSpotifyStart`, `toggleSongLog`) flips a flag on the `SpotifyManager` and persists it. Owns notification delivery via `UserNotifications`.
- **`SpotifyManager.swift`** — all the actual ad-muting logic. Created by `AppDelegate` with a `titleChangeHandler` closure that updates the menu-bar glyph.
- **`StatusBarTitle.swift`** — the two menu-bar glyphs: `☀︎` (no ad) / `☂︎` (ad / busy).

### How muting works (the core mechanism)

The app is event-driven, not polling, which is why it's CPU-cheap:

1. `SpotifyManager.startWatchingForFileChanges()` builds a list of Spotify state files under `~/Library/Application Support/Spotify/Users/<user>-user/` (`recently_played.bnk`, `ad-state-storage.bnk`, and their `.tmp` variants) and registers an **FSEvents** stream on them. Spotify rewrites these files on every track change.
2. On any file event, `handleTrackChanged()` runs. It calls AppleScript (`osascript`) to read the current track's `spotify url`. If it starts with `spotify:ad`, that's an ad.
3. **Mute mode** (default): saves the current volume, sets Spotify volume to 0, restores it when a real track returns. It deliberately does *not* restore if the user changed the volume to non-zero during the ad.
4. **Restart-to-skip mode** (`restartToSkipAdsEnabled`): instead of muting, quits and relaunches Spotify to skip the ad. Focus restoration (`captureFocusRestoreTarget` / `restoreFocusAfterRestartIfNeeded` / `scheduleFocusRestoreRetries`) tries to return the user to whatever app was frontmost so the restart doesn't steal focus. `isRestarting` guards the quit/relaunch flow so the "Spotify quit → terminate ourselves" observer doesn't fire mid-restart.

All Spotify interaction goes through `runAppleScript(script:)`, which shells out to `/usr/bin/osascript`. The Spotify-control scripts are prefixed with `appleScriptSpotifyPrefix` (`tell application "Spotify" to ...`).

### Other behaviors

- **Endless private session** (`enablePrivateSession`/`disablePrivateSession`): clicks Spotify's "Private Session" menu item via AppleScript driving System Events. **Requires Accessibility + Automation permissions** (System Settings → Privacy & Security). Re-asserted ~2s after each track change while enabled.
- **Song log**: when a log path is set, `logSong()` appends a CSV row of track metadata (read via AppleScript) on each new song.
- **Lifecycle coupling**: the app launches Spotify on start (when `startSpotify` is on) and terminates itself when Spotify quits, via an `NSWorkspace` termination observer. Spotify is launched with `open -g -j` (background, hidden) to avoid stealing focus.

## Key constraints when editing

- The app runs as an `LSUIElement` (no Dock icon, menu-bar only — set in `Info.plist`).
- Hardened runtime is enabled and `NSAppleEventsUsageDescription` / the `com.apple.security.automation.apple-events` entitlement are required for the AppleScript automation to work. Don't remove them.
- Bundle identifier is `de.simonmeusel.MuteSpotifyAds` (kept from upstream); deployment target is macOS 11.0; builds universal via `ARCHS_STANDARD`.
- Status-bar UI setup in `applicationDidFinishLaunching` is intentionally deferred with `DispatchQueue.main.async` to avoid AppKit menu-bar layout recursion — keep that pattern.
- UI strings are localized under `*.lproj/MainMenu.strings` (Chinese, English, German, Italian, Spanish, Turkish). Menu structure lives in `Base.lproj/MainMenu.xib`.

## License / fork obligations

GPLv3. Preserve copyright and attribution notices (`LICENSE`, `NOTICE`). Any redistribution of binaries must ship corresponding source — that's why `package_release.sh` also produces the source archive.
