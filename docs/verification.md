# Local verification — 10 October 2026

Environment: Apple Silicon Mac, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4.
Minimum supported macOS is now 12.0; login items still require macOS 13.

- `swift test`: 11 state-machine cases passed.
- `scripts/test_macos_integration.sh`: 16 checks passed. The shipping manager and settings
  classes use simulated Spotify replies; the shipping filler uses a real generated silent WAV
  and AVAudioPlayer. Checks cover mute/unmute, unknown readings, volume persistence,
  preserving user volume changes, existing mute, unreadable volume, crash recovery, quit
  recovery, mutually exclusive modes, value clamping, scanning, playback and fade teardown.
  This executable uses its own defaults domain and stdout diagnostics, preserving app settings.
- Debug build: native arm64, ad-hoc code signature verified. `Mutefy.app` launched from
  `build-debug/Build/Products/Debug/`. The live log confirmed Spotify track metadata and
  volume reads, plus an existing filler folder scan finding 11 files.
- Release packaging: universal arm64/x86_64, with matching source snapshot and SHA-256 sums.
- Shell syntax, Homebrew cask Ruby syntax and `git diff --check` passed.

The Computer Use tool rejected access to Mutefy, so status-menu and settings-window
interactions were not checked. No real advertisement mute/unmute was observed in this run.
Packaging does not upload or publish the release. Signing is ad-hoc, without notarization.
