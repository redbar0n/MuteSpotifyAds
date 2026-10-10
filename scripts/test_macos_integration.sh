#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mutefy-integration.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

# Compile the shipping classes directly; mock only the Spotify AppleScript boundary.
# No Spotify account, Automation permission, or changes to the app's settings are needed.
xcrun swiftc -target "$(uname -m)-apple-macos12.0" -o "${TEST_DIR}/MutefyIntegrationTests" \
  "${ROOT_DIR}/MuteSpotifyAds/AdStateMachine.swift" \
  "${ROOT_DIR}/MuteSpotifyAds/SpotifyManager.swift" \
  "${ROOT_DIR}/MuteSpotifyAds/StatusBarTitle.swift" \
  "${ROOT_DIR}/MuteSpotifyAds/MutefySettings.swift" \
  "${ROOT_DIR}/MuteSpotifyAds/FillerPlayer.swift" \
  "${ROOT_DIR}/MuteSpotifyAds/LaunchAtLogin.swift" \
  "${ROOT_DIR}/MuteSpotifyAds/SettingsWindowController.swift" \
  "${ROOT_DIR}/Tests/macOSIntegration/main.swift"
"${TEST_DIR}/MutefyIntegrationTests" "${TEST_DIR}"
