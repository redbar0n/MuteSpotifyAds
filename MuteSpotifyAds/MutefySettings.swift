//
//  MutefySettings.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//

import Foundation

/// UserDefaults-backed settings. One property per key, following the key naming already
/// used by this app (PascalCase strings), so the existing menu toggles and the new
/// settings window read from the same place.
///
/// Values are clamped on read rather than on write: defaults edited by hand with
/// `defaults write` should not be able to produce a 30-second fade or a zero-second
/// safety ceiling.
enum MutefySettings {

    // MARK: - Keys

    enum Key {
        // Inherited from MuteSpotifyAds.
        static let endlessPrivateSession = "EndlessPrivateSession"
        static let restartToSkipAds = "RestartToSkipAds"
        static let startSpotify = "StartSpotify"
        static let notifications = "Notifications"
        static let songLogPath = "SongLogPath"

        // Added by Mutefy.
        static let fillerEnabled = "FillerEnabled"
        static let fillerFolderPath = "FillerFolderPath"
        static let fillerRecursive = "FillerRecursive"
        static let fillerVolumePercent = "FillerVolumePercent"
        static let fillerFadeInMs = "FillerFadeInMs"
        static let fillerFadeOutMs = "FillerFadeOutMs"
        static let fillerStartDelayMs = "FillerStartDelayMs"
        static let maxMuteSeconds = "MaxMuteSeconds"
        static let adEnterDebounceMs = "AdEnterDebounceMs"
        static let launchAtLogin = "LaunchAtLogin"

        /// Spotify's volume before we muted it, persisted immediately.
        ///
        /// The app this forks from kept it in memory only, so a crash or force-quit during
        /// an ad left Spotify silent with nothing able to restore it. -1 means "we are not
        /// holding anyone's volume".
        static let savedSpotifyVolume = "SavedSpotifyVolume"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - Filler

    static var fillerEnabled: Bool {
        get { defaults.bool(forKey: Key.fillerEnabled) }
        set { defaults.set(newValue, forKey: Key.fillerEnabled) }
    }

    static var fillerFolderPath: String {
        get { defaults.string(forKey: Key.fillerFolderPath) ?? "" }
        set { defaults.set(newValue, forKey: Key.fillerFolderPath) }
    }

    static var fillerRecursive: Bool {
        get { object(Key.fillerRecursive) == nil ? true : defaults.bool(forKey: Key.fillerRecursive) }
        set { defaults.set(newValue, forKey: Key.fillerRecursive) }
    }

    /// Filler playback volume, independent of Spotify's own.
    static var fillerVolumePercent: Int {
        get { clamped(Key.fillerVolumePercent, default: 60, min: 0, max: 100) }
        set { defaults.set(newValue, forKey: Key.fillerVolumePercent) }
    }

    /// Short on purpose — the ad is already playing under the mute, so the sooner there is
    /// something to hear the better.
    static var fillerFadeInMs: Int {
        get { clamped(Key.fillerFadeInMs, default: 400, min: 0, max: 5_000) }
        set { defaults.set(newValue, forKey: Key.fillerFadeInMs) }
    }

    /// Three times the fade in: when the ad ends Spotify is already audible again, so this
    /// is a hand-off rather than a stop. Anything under about a second reads as a cut-off.
    static var fillerFadeOutMs: Int {
        get { clamped(Key.fillerFadeOutMs, default: 1_200, min: 0, max: 8_000) }
        set { defaults.set(newValue, forKey: Key.fillerFadeOutMs) }
    }

    /// Grace period before the filler starts, so a momentary false positive does not
    /// produce an audible blip.
    static var fillerStartDelayMs: Int {
        get { clamped(Key.fillerStartDelayMs, default: 250, min: 0, max: 5_000) }
        set { defaults.set(newValue, forKey: Key.fillerStartDelayMs) }
    }

    // MARK: - Advanced

    /// Hard ceiling on a single mute. A measured Korean free-account break ran 56 seconds
    /// (two ads back to back), so this has to clear well over a minute — tripping early
    /// means the rest of the break plays at full volume.
    static var maxMuteSeconds: Int {
        get { clamped(Key.maxMuteSeconds, default: 180, min: 10, max: 600) }
        set { defaults.set(newValue, forKey: Key.maxMuteSeconds) }
    }

    static var adEnterDebounceMs: Int {
        get { clamped(Key.adEnterDebounceMs, default: 150, min: 0, max: 3_000) }
        set { defaults.set(newValue, forKey: Key.adEnterDebounceMs) }
    }

    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    // MARK: - Crash recovery

    static var savedSpotifyVolume: Int {
        get { object(Key.savedSpotifyVolume) == nil ? -1 : defaults.integer(forKey: Key.savedSpotifyVolume) }
        set {
            defaults.set(newValue, forKey: Key.savedSpotifyVolume)
            // Written through immediately: the whole point is to survive a force-quit.
            defaults.synchronize()
        }
    }

    // MARK: - Helpers

    private static func object(_ key: String) -> Any? {
        defaults.object(forKey: key)
    }

    /// Escape hatch for the keys inherited from MuteSpotifyAds, which the status menu still
    /// owns. Lets the settings window write them without duplicating the menu's logic.
    static func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private static func clamped(_ key: String, default fallback: Int, min lower: Int, max upper: Int) -> Int {
        guard object(key) != nil else { return fallback }
        return Swift.min(upper, Swift.max(lower, defaults.integer(forKey: key)))
    }
}
