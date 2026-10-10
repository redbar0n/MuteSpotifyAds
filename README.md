#  Mutefy

[![macOS version support](https://img.shields.io/badge/macOS-12%2B-brightgreen.svg)](https://github.com/countnine/MuteSpotifyAds/releases)
[![license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A native, efficient macOS menu bar app that automatically silences ads in the Spotify desktop
app — and, if you want, plays your own music over the silence instead of leaving you with a
minute of nothing.

This application is not in any way affiliated with Spotify.

## Project origin

This repository is a fork of MuteSpotifyAds, renamed to **Mutefy** in version 2.0.0 when the
features from the Windows/Android [Mutefy](https://github.com/countnine/mutefy) builds were
brought over.

- Original upstream (archived): https://github.com/simonmeusel/MuteSpotifyAds
- Intermediate fork: https://github.com/MikeWLloyd/MuteSpotifyAds
- This fork: https://github.com/countnine/MuteSpotifyAds

Everything MuteSpotifyAds did still works. The rename reflects that this is now the macOS
member of a three-platform family, not that the original was replaced.

## What Mutefy adds

| Feature | Why |
|---|---|
| **Filler music** | A measured Korean free-account ad break ran **56 seconds** (two ads back to back). Instead of silence, Mutefy plays a random track from a folder you choose, fading in and out. |
| **Fade in / out** | The fade out is 1200 ms against a 400 ms fade in: when the ad ends Spotify is already audible, so this is a hand-off rather than a stop. Anything under about a second reads as being cut off. |
| **Safety ceiling** | If detection dies mid-ad, the original would leave Spotify silent forever. Past a configurable ceiling (default 180 s) Mutefy forces the volume back and refuses to re-mute until detection says something else. |
| **Entry debounce** | Spotify blanks its metadata for a moment between tracks, which looks exactly like an ad. A verdict has to hold (default 150 ms) before muting. Leaving an ad is never debounced — leaving music muted is the worse failure. |
| **Crash recovery** | The pre-mute volume is written to disk *before* muting, so a force-quit during an ad no longer leaves Spotify permanently silent. The next launch restores it. |
| **Fallback poll** | The original reacted only to Spotify's file writes. That is efficient, but the safety ceiling can only fire when something asks — so a detector that has stopped producing events would never rescue a stuck mute. A 500 ms poll backs the file watcher up. |
| **Settings window** | The original was menu toggles only, with no way to pick a folder. |
| **Korean** | `ko.lproj`, joining the six existing languages. |
| **Open at login** | Via `SMAppService` on macOS 13+. |
| **Diagnostic log** | `~/Library/Logs/Mutefy/mutefy.log` records every state change, volume write and filler start. "The volume stayed at zero" is silent and undiagnosable from the outside otherwise. |

Filler music and *Restart to skip ads* are mutually exclusive: restarting Spotify removes the
ad the filler exists to cover.

## Features

* Mute ads
* Play your own music over the muted stretch, with fades
* Restart Spotify to skip ads (alternative to muting)
* Endless private session
* Song log file
* Auto-start Spotify with Mutefy, or open Mutefy at login

## Usage

Start Mutefy. It will mute any ad it sees and restore your volume when music returns.

Click the `☂︎` in the menu bar for the toggles, or **Settings…** for the filler folder, volume,
fade times and the safety ceiling.

If you enable filler music, choose a folder containing `.mp3`, `.m4a`, `.aac`, `.wav`, `.aiff`
or `.flac` files. Tracks are drawn without replacement, so nothing repeats until the folder has
been exhausted, and a track that ends before the ad does hands over to the next one.

## How it works

Whenever the track changes, Spotify modifies these files:

```
~/Library/Application Support/Spotify/Users/($SPOTIFY_USER_NAME)-user/recently_played.bnk
~/Library/Application Support/Spotify/Users/($SPOTIFY_USER_NAME)-user/ad-state-storage.bnk
```

Mutefy watches them and, when one changes, asks Spotify what is playing:

```
tell application "Spotify" to (get spotify url of current track)
```

If the URL starts with `spotify:ad`, it is an ad. This is an exact answer, not a guess — which
is why the macOS build needs none of the localised-string heuristics the Windows build
required. Volume is read and written with:

```
tell application "Spotify" to (get sound volume)
tell application "Spotify" to set sound volume to ($VOLUME)
```

Note that Spotify stores the volume with a little loss: asking for 94 reads back 93. Mutefy
verifies its writes and only logs a genuine disagreement.

## Installation

Manual installation:

1. Download from the [releases page](https://github.com/countnine/MuteSpotifyAds/releases/)
2. Move it to your Applications folder
3. Run it using **Right Click → Open** on first launch
4. Grant Automation access to Spotify when macOS asks. Without it Mutefy can see nothing and
   will sit there doing nothing — check the log if you are unsure

This project targets macOS `12+`. *Open at login* requires macOS 13+ and is hidden below that.

To uninstall, trash `Mutefy.app`.

> **Homebrew:** `Casks/mutefy.rb` installs `Mutefy.app` from this fork. The release must
> contain `Mutefy.app.tar.gz` before the cask can be installed.

### Troubleshooting

Check `~/Library/Logs/Mutefy/mutefy.log` first. Every state change is in there with a
timestamp. In particular, a log where every line says `reading: unknown` means Spotify is not
answering — usually missing Automation permission.

If the application does not work, follow the steps for enabling an endless private Spotify
session below.

## Endless private Spotify session

You can also use this application to enforce an endless private session. **This requires
additional privileges.** To enable them:

1. `System Settings` → `Privacy & Security` → `Accessibility` → enable Mutefy
2. `System Settings` → `Privacy & Security` → `Automation` → enable Mutefy for `Spotify` and
   `System Events`

To enable/disable it, click the `☂︎` in the menu bar, then `∞ Private session`. This ensures
the Spotify private session is enabled whenever the current song changes.

This application enables the private session using
[the following apple script](https://stackoverflow.com/a/51068836/6286431):

```
tell application "System Events" to tell process "Spotify"
tell menu bar item 2 of menu bar 1 -- AppleScript indexes are 1-based
tell menu item "Private Session" of menu 1
set isChecked to value of attribute "AXMenuItemMarkChar" is "✓"
if not isChecked then click it
end tell
end tell
end tell
```

## Development

```sh
# Unit tests for the ad state machine — no Mac UI, Spotify or account needed
swift test

# macOS integration checks: mock Spotify, real silent AVAudioPlayer playback
scripts/test_macos_integration.sh

# Build a Debug app for this Mac (Xcode 27 supported)
xcodebuild -project MuteSpotifyAds.xcodeproj -scheme MuteSpotifyAds -configuration Debug -derivedDataPath build-debug build
open build-debug/Build/Products/Debug/Mutefy.app
```

`Package.swift` exists purely to put XCTest around `AdStateMachine.swift`. It compiles the very
same file the app target does, so the tests cannot drift from what ships. The macOS integration
script compiles the shipping manager, settings and filler classes, mocks Spotify's AppleScript
replies, sends diagnostics to stdout, and exercises real silent WAV playback. Live advertising
still needs a real free Spotify account and a real ad break — see
[docs/porting-from-windows.md](docs/porting-from-windows.md) for what was measured.

The Xcode target and source directory are still named `MuteSpotifyAds`; only the product,
bundle identifier (`com.countnine.mutefy`) and Swift module are `Mutefy`. Renaming the target
is a separate, riskier change best done in Xcode itself.

### Release packaging

Run `scripts/package_release.sh` to create a universal `arm64` / `x86_64` Release app,
`Mutefy-source.tar.gz`, and `checksums.txt` under `dist/`. The script snapshots tracked and
unignored new files from the working tree, then builds that snapshot. Uncommitted changes
are included in both the app and its corresponding source; ignored build output is excluded.
Git LFS icon files must be checked out as actual PNGs (`git lfs pull` if needed).
The cask pins each release and its binary checksum; update both when publishing a new version.

Before publishing, run `swift test` and `scripts/test_macos_integration.sh`, review the source
archive, and upload all three artifacts
to a release in `countnine/MuteSpotifyAds`. Packaging does not publish anything. The app is
ad-hoc signed for local use; it is not notarized.

## Contributing

If you want to contribute, feel free to do so. If you need help, just open an issue.

You can also contribute by adding a language. Add a `*.lproj/MainMenu.strings` for the menu and
a `*.lproj/Localizable.strings` for the settings window; anything missing falls back to English.

Currently supported languages:

* Chinese
* English
* German
* Italian
* Korean
* Spanish
* Turkish

## Thanks

Thanks to [Simon Meusel](https://github.com/simonmeusel) for the original application, and to
[MikeWLloyd](https://github.com/MikeWLloyd) for modernising it for current macOS.
Thanks to [Carlo Federico Vescovo](https://github.com/cfvescovo) for the restart-spotify
feature, the auto-start option and help with the documentation!
Thanks to [Artem Gordinsky](https://github.com/ArtemGordinsky/) and the
[other contributors](https://github.com/ArtemGordinsky/Spotifree#thanks) of
[Spotifree](https://github.com/ArtemGordinsky/Spotifree)!
Thanks to [vadian](https://stackoverflow.com/users/5044042/vadian) for the
[help](https://stackoverflow.com/questions/51068410/osx-tick-menu-bar-checkbox/51068836#51068836)!

## License

[GNU General Public License v3.0](LICENSE)

Copyright (C) 2018 Simon Meusel
Copyright (C) 2026 MikeWLloyd contributors
Copyright (C) 2026 countnine

### GPLv3 compliance notes for this fork

- This fork preserves the original GPLv3 licensing and attribution.
- A fork attribution/change notice is provided in `NOTICE`.
- If you redistribute this app (including binaries), you must also provide the corresponding
  source code for the distributed version under GPLv3 terms.
- Include the GPLv3 license text (`LICENSE`) and preserve copyright/attribution notices in
  source and releases.
- Code brought over from the Windows build of Mutefy is also GPL-3.0, so no relicensing was
  involved.
