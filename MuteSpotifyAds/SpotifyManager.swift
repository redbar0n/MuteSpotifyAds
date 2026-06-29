//
//  SpotifyManager.swift
//  MuteSpotifyAds
//
//  Created by Simon Meusel on 29.05.18.
//  Copyright © 2019 Simon Meusel. All rights reserved.
//

import Cocoa

class SpotifyManager: NSObject {

    static let appleScriptSpotifyPrefix = "tell application \"Spotify\" to "
    static let spotifyBundleIdentifier = "com.spotify.client"
    /// Distributed notification Spotify broadcasts on every play/pause/track change.
    static let playbackStateChangedNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    /// Result of trying to read whether an ad is currently playing.
    /// `.unknown` means Spotify gave us no usable answer (transient error / between tracks)
    /// and we must NOT change state based on it.
    enum AdState {
        case ad
        case noAd
        case unknown
    }

    var titleChangeHandler: ((StatusBarTitle) -> Void)
    var fileEventStream: FSEventStreamRef?

    var endlessPrivateSessionEnabled = false
    var restartToSkipAdsEnabled = false
    var songLogPath: String? = nil
    var startSpotify = false

    /**
     * Volume before mute, between 0 and 100
     */
    var spotifyUserVolume = 0
    /**
     * Whether spotify is being muted
     */
    var muted = false
    /**
     * Whether Spotify is getting restarted
     */
    var isRestarting = false
    var focusRestoreBundleIdentifier: String? = nil

    var lastSongSpotifyURL: String = ""

    /// Serial queue that all ad detection / muting runs on. Multiple event sources
    /// (FSEvents, the Spotify playback notification, the watchdog timer, startup)
    /// feed into `handleTrackChanged()`, so serializing keeps `muted` / `spotifyUserVolume`
    /// consistent and avoids overlapping AppleScript calls.
    let workQueue = DispatchQueue(label: "de.simonmeusel.MuteSpotifyAds.work")

    /// Timer that only runs while an ad is muted. It re-asserts mute if Spotify lets the
    /// volume creep back up, and restores volume if we missed the ad→track event entirely.
    var adWatchdog: DispatchSourceTimer?

    /// How many times we've retried locating Spotify's user state folder for the file watcher.
    var fileWatcherAttempts = 0

    init(titleChangeHandler: @escaping ((StatusBarTitle) -> Void)) {
        self.titleChangeHandler = titleChangeHandler

        super.init()

        // Stop this application when Spotify gets closed
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil, using: {
            notification in

            if self.startSpotify {
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as! NSRunningApplication
                if (app.bundleIdentifier == SpotifyManager.spotifyBundleIdentifier) {
                    self.handleSpotifyQuit()
                }
            }
        })

        // (Improvement ①) Spotify broadcasts a distributed notification on every playback
        // state change. This is far more reliable and timely than watching the .bnk files,
        // and it keeps working even when the file watcher couldn't be set up (e.g. the user
        // folder didn't exist yet at launch).
        DistributedNotificationCenter.default().addObserver(
            forName: SpotifyManager.playbackStateChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleTrackChangeHandling()
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        stopAdWatchdog()
    }

    func handleSpotifyQuit() {
        if (isRestarting) {
            // Restart flow is handled by restartSpotify(). Avoid duplicate
            // spotifyPlay() calls here because they can re-activate Spotify.
            return
        } else {
            NSApplication.shared.terminate(self)
        }
    }

    func isSpotifyPaused() -> Bool {
        return runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "(get player state)") == "paused"
    }

    /// Coalesce all event sources onto the serial work queue.
    func scheduleTrackChangeHandling() {
        workQueue.async { [weak self] in
            _ = self?.handleTrackChanged()
        }
    }

    func startWatchingForFileChanges() {
        if startSpotify {
            DispatchQueue.global(qos: .default).async {
                self.startSpotify(foreground: false)
                self.scheduleTrackChangeHandling()
            }
        }

        setupFileWatcher()
    }

    /// Builds the list of Spotify state files to watch. Returns an empty array when the
    /// Spotify user folder doesn't exist yet (e.g. not logged in / just launched).
    func spotifyUserStateFiles() -> [String] {
        var path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        path.appendPathComponent("Spotify")
        path.appendPathComponent("Users")

        guard let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants], errorHandler: nil) else {
            return []
        }

        var files: [String] = []
        while let file = enumerator.nextObject() as? URL {
            if file.path.hasSuffix("-user") {
                files.append(file.appendingPathComponent("recently_played.bnk.tmp").path)
                files.append(file.appendingPathComponent("ad-state-storage.bnk.tmp").path)
                files.append(file.appendingPathComponent("recently_played.bnk").path)
                files.append(file.appendingPathComponent("ad-state-storage.bnk").path)
            }
        }
        return files
    }

    /// (Improvement ①) Sets up the FSEvents watcher. If the user folder isn't available yet
    /// the watcher can't be created, so we retry a few times; detection still works in the
    /// meantime via the Spotify playback notification.
    func setupFileWatcher() {
        if fileEventStream != nil {
            return
        }

        let files = spotifyUserStateFiles()
        if files.isEmpty {
            fileWatcherAttempts += 1
            if fileWatcherAttempts <= 20 {
                DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.setupFileWatcher()
                }
            }
            return
        }

        // Create file watcher with context
        var context = FSEventStreamContext(version: 0, info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), retain: nil, release: nil, copyDescription: nil)
        fileEventStream = FSEventStreamCreate(kCFAllocatorDefault, {
            _, info, _, _, _, _ in

            Unmanaged<SpotifyManager>.fromOpaque(info!).takeUnretainedValue().scheduleTrackChangeHandling()
        }, &context, files as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))

        if let stream = fileEventStream {
            FSEventStreamScheduleWithRunLoop(stream, RunLoop.current.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    func startSpotify(foreground: Bool) {
        let process = Process()
        // Open application with bundle identifier
        process.launchPath = "/usr/bin/open"

        var arguments: [String] = []
        if (!foreground) {
            // Use documented open(1) flags to avoid app activation/focus steal.
            arguments += ["-g", "-j"]
        }
        arguments += ["-b", SpotifyManager.spotifyBundleIdentifier]

        process.arguments = arguments
        process.launch()
        process.waitUntilExit()
    }

    /**
     * Enables private Spotify session
     */
    func enablePrivateSession() {
        // See https://stackoverflow.com/questions/51068410/osx-tick-menu-bar-checkbox/51068836#51068836
        let script = """
            tell application \"System Events\" to tell process \"Spotify\"
                tell menu bar item 2 of menu bar 1
                    tell menu item \"Private Session\" of menu 1
                        set isChecked to value of attribute \"AXMenuItemMarkChar\" is \"✓\"
                        if not isChecked then click it
                    end tell
                end tell
            end tell
            """
        _ = runAppleScript(script: script)
    }

    /**
     * Disables private Spotify session
     */
    func disablePrivateSession() {
        // See https://stackoverflow.com/questions/51068410/osx-tick-menu-bar-checkbox/51068836#51068836
        let script = """
            tell application \"System Events\" to tell process \"Spotify\"
                tell menu bar item 2 of menu bar 1
                    tell menu item \"Private Session\" of menu 1
                        set isChecked to value of attribute \"AXMenuItemMarkChar\" is \"✓\"
                        if isChecked then click it
                    end tell
                end tell
            end tell
            """
        _ = runAppleScript(script: script)
    }

    /**
     * Checks for a currently playing ad and mutes / restores accordingly.
     *
     * Returns true if spotify got muted or unmuted, false otherwise.
     * Runs on `workQueue` (serialized) for all event sources.
     */
    func handleTrackChanged() -> Bool {
        var changed = false

        // (Improvement ②) Retry a couple of times: right at a track transition the AppleScript
        // query can briefly return an empty/stale value, which previously made us miss the ad.
        let state = detectAd(retries: 2)

        switch state {
        case .ad:
            if restartToSkipAdsEnabled {
                restartSpotify()
            } else if !muted {
                if let volume = getSpotifyVolume() {
                    spotifyUserVolume = volume
                }
                setSpotifyVolume(volume: 0)
                muted = true
                titleChangeHandler(.ad)
                changed = true
                startAdWatchdog()
            }
        case .noAd:
            // Reactivate spotify if ad is done
            if muted {
                // Don't change volume if user manually changed it
                if let volume = getSpotifyVolume(), volume == 0 && spotifyUserVolume != 0 {
                    setSpotifyVolume(volume: spotifyUserVolume)
                }
                muted = false
                titleChangeHandler(.noAd)
                changed = true
                stopAdWatchdog()
            }
        case .unknown:
            // Couldn't determine state — leave everything as-is rather than
            // wrongly unmuting (which is what the old single-shot check did).
            break
        }

        if endlessPrivateSessionEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: {
                self.enablePrivateSession()
            })
        }

        if songLogPath != nil {
            logSong()
        }

        return changed
    }

    /// (Improvement ③) While an ad is muted, periodically re-check Spotify. This recovers from
    /// two failure modes that the event-driven path alone can't: Spotify resetting the volume
    /// back up mid-ad, and a missed ad→track event leaving us muted forever.
    func startAdWatchdog() {
        stopAdWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.adWatchdogTick()
        }
        adWatchdog = timer
        timer.resume()
    }

    func stopAdWatchdog() {
        adWatchdog?.cancel()
        adWatchdog = nil
    }

    func adWatchdogTick() {
        guard muted else {
            stopAdWatchdog()
            return
        }

        switch detectAd(retries: 1) {
        case .ad:
            // Re-assert mute: if Spotify (not the user's intent) let the volume climb back up
            // during the ad, force it back to 0 so the ad stays silent.
            if let volume = getSpotifyVolume(), volume != 0 {
                setSpotifyVolume(volume: 0)
            }
        case .noAd:
            // We missed the ad→track transition event; restore and stop watching.
            if let volume = getSpotifyVolume(), volume == 0 && spotifyUserVolume != 0 {
                setSpotifyVolume(volume: spotifyUserVolume)
            }
            muted = false
            titleChangeHandler(.noAd)
            stopAdWatchdog()
        case .unknown:
            break
        }
    }

    func setSpotifyVolume(volume: Int) {
        _ = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "set sound volume to \(volume)")
    }

    /**
     * Gets current spotify volume, or nil if Spotify gave no parseable answer.
     */
    func getSpotifyVolume() -> Int? {
        let output = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "(get sound volume)")
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? output
        return Int(firstLine.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /**
     * (Improvement ②) Determines whether an ad is playing, retrying when Spotify returns an
     * empty value. The current track's spotify url is `spotify:ad:...` during ads.
     */
    func detectAd(retries: Int = 0) -> AdState {
        for attempt in 0...max(0, retries) {
            let spotifyURL = getCurrentSongSpotifyURL()
            if spotifyURL.isEmpty {
                if attempt < retries {
                    // Brief pause before re-querying; we're on a serial queue so this is fine.
                    usleep(200_000)
                }
                continue
            }
            return spotifyURL.starts(with: "spotify:ad") ? .ad : .noAd
        }
        return .unknown
    }

    func getCurrentSongSpotifyURL() -> String {
        return runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "(get spotify url of current track)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func captureFocusRestoreTarget() {
        let capture = {
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
                  let frontmostBundleIdentifier = frontmostApp.bundleIdentifier else {
                self.focusRestoreBundleIdentifier = nil
                return
            }

            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            if frontmostBundleIdentifier == SpotifyManager.spotifyBundleIdentifier || frontmostBundleIdentifier == ownBundleIdentifier {
                self.focusRestoreBundleIdentifier = nil
                return
            }

            self.focusRestoreBundleIdentifier = frontmostBundleIdentifier
        }

        if Thread.isMainThread {
            capture()
        } else {
            DispatchQueue.main.sync(execute: capture)
        }
    }

    func restoreFocusAfterRestartIfNeeded() {
        DispatchQueue.main.async {
            guard let targetBundleIdentifier = self.focusRestoreBundleIdentifier else {
                return
            }

            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            guard let currentFrontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
                return
            }

            // If user already switched to another app, do not steal focus back.
            if currentFrontmostBundleIdentifier != SpotifyManager.spotifyBundleIdentifier && currentFrontmostBundleIdentifier != ownBundleIdentifier {
                return
            }

            guard let appToRestore = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == targetBundleIdentifier
            }) else {
                return
            }

            _ = appToRestore.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func scheduleFocusRestoreRetries() {
        let retryDelays: [Double] = [0.4, 1.0, 2.0, 4.0, 7.0]
        for delay in retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: {
                self.restoreFocusAfterRestartIfNeeded()
            })
        }
    }

    func restartSpotify() {
        isRestarting = true
        titleChangeHandler(.ad)
        captureFocusRestoreTarget()
        _ = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "quit")
        startSpotify(foreground: false)
        scheduleFocusRestoreRetries()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: {
            self.spotifyPlay()
            self.restoreFocusAfterRestartIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: {
                self.spotifyPlay()
                self.restoreFocusAfterRestartIfNeeded()
                self.titleChangeHandler(.noAd)
                self.isRestarting = false
                self.focusRestoreBundleIdentifier = nil
            })
        })
    }

    func quitSpotify() {
        titleChangeHandler(.ad)
        _ = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "quit")
    }

    /**
     * Runs the given apple script and returns its stdout, or an empty string on failure.
     */
    func runAppleScript(script: String) -> String {
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        // Swallow stderr so AppleScript errors (e.g. Spotify mid-transition) don't spam.
        process.standardError = Pipe()

        process.launch()
        // Read before waiting to avoid deadlocking on a full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: String.Encoding.utf8) ?? ""
    }

    func toggleSpotifyPlayPause() {
        _ = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "playpause")
    }

    func spotifyPlay() {
        _ = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "play")
    }

    /**
     * Log information about the current song to the song log file
     */
    func logSong() {
        let currentSongSpotifyURL = getCurrentSongSpotifyURL()
        if (lastSongSpotifyURL == currentSongSpotifyURL) {
            return
        }
        lastSongSpotifyURL = currentSongSpotifyURL

        var script = "set o to \"\"\n"
        let songProperties = ["name", "artist", "album", "disc number", "duration", "played count", "track number", "popularity", "id", "artwork url", "album artist", "spotify url"]
        for property in songProperties {
            script += "tell application \"Spotify\"\nset o to o & \"\n\" & (get " + property + " of current track)\nend tell\n"
        }

        var logEntry = runAppleScript(script: script).replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: ",")
        if logEntry == "" {
            return
        }
        logEntry.removeFirst()
        logEntry.removeLast()
        logEntry += "," + Date().description + "\n"

        if !FileManager.default.fileExists(atPath: songLogPath!) {
            FileManager.default.createFile(atPath: songLogPath!, contents: (songProperties.joined(separator: ",") + ",date\n").data(using: .utf8), attributes: nil)
        }

        if let fileUpdater = try? FileHandle(forUpdating: URL(fileURLWithPath: songLogPath!)) {
            fileUpdater.seekToEndOfFile()
            fileUpdater.write(logEntry.data(using: .utf8)!)
            fileUpdater.closeFile()
        }
    }

}
