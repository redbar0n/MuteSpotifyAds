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

    /// Debounce + safety ceiling. See AdStateMachine for why both are needed.
    var stateMachine = AdStateMachine(
        enterDebounce: Double(MutefySettings.adEnterDebounceMs) / 1000.0,
        maxAdDuration: Double(MutefySettings.maxMuteSeconds))

    let filler = FillerPlayer()

    /// Fallback poll. File-change events drive most updates, but the safety ceiling only
    /// advances when something calls `evaluate()` — a detector that has stopped producing
    /// events would otherwise never reach its own ceiling and the mute would stick forever.
    private var pollTimer: DispatchSourceTimer?
    private static let pollInterval: TimeInterval = 0.5

    /// Serialises evaluation: file events, the poll timer and manual nudges all land here.
    private let evaluationQueue = DispatchQueue(label: "com.countnine.mutefy.evaluate")

    init(titleChangeHandler: @escaping ((StatusBarTitle) -> Void)) {
        self.titleChangeHandler = titleChangeHandler

        super.init()

        // Stop this application when Spotify gets closed
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil, using: {
            notification in
            
            if self.startSpotify {
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as! NSRunningApplication
                if (app.bundleIdentifier == "com.spotify.client") {
                    self.handleSpotifyQuit()
                }
            }
        })
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
    
    func startWatchingForFileChanges() {
        if startSpotify {
            DispatchQueue.global(qos: .default).async {
                self.startSpotify(foreground: false)
                _ = self.handleTrackChanged()
            }
        }
        
        var path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        path.appendPathComponent("Spotify")
        path.appendPathComponent("Users")
        
        let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants], errorHandler: nil)
        
        var files: [String] = []
        
        while let file = enumerator?.nextObject() as? URL {
            if file.path.hasSuffix("-user") {
                files.append(file.appendingPathComponent("recently_played.bnk.tmp").path)
                files.append(file.appendingPathComponent("ad-state-storage.bnk.tmp").path)
                files.append(file.appendingPathComponent("recently_played.bnk").path)
                files.append(file.appendingPathComponent("ad-state-storage.bnk").path)
            }
        }
        
        // Create file watcher with context
        var context = FSEventStreamContext(version: 0, info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), retain: nil, release: nil, copyDescription: nil)
        fileEventStream = FSEventStreamCreate(kCFAllocatorDefault, {
            _, info, _, _, _, _ in
            
            DispatchQueue.global(qos: .default).async {
                _ = Unmanaged<SpotifyManager>.fromOpaque(
                    info!).takeUnretainedValue().handleTrackChanged()
            }
        }, &context, files as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        
        FSEventStreamScheduleWithRunLoop(fileEventStream!, RunLoop.current.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(fileEventStream!)
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
        arguments += ["-b", "com.spotify.client"]
        
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
     * Checks for a currently playing ad
     *
     * Returns true if spotify got muted or unmuted, false otherwise
     */
    @discardableResult
    func handleTrackChanged() -> Bool {
        // Everything funnels through one serial queue. Without it a file event and a poll
        // tick can both decide to mute, read each other's half-applied state, and leave
        // `spotifyUserVolume` holding 0 — which is exactly the value we must never save.
        evaluationQueue.sync {
            evaluate()
        }
    }

    /// Last raw reading, so a change in what the probe *sees* can be logged separately from
    /// a change in what the state machine *decides*.
    private var lastReading: AdReading?

    /// Reads one sample, advances the state machine, and acts only on transitions.
    private func evaluate() -> Bool {
        let reading = readAd()

        // Logged because the most damaging failure here is silent: if Automation permission
        // is refused, every read returns nothing, the machine holds forever and the app
        // looks alive while doing nothing at all. A reading that never leaves `unknown` is
        // the signature of that, and it is only visible if we say so.
        if reading != lastReading {
            lastReading = reading
            mutefyLog("reading: \(reading) (\(describeCurrentTrack()))")
        }

        let trips = stateMachine.safetyTrips
        let changed = stateMachine.advance(reading)

        if stateMachine.safetyTrips > trips {
            mutefyLog("SAFETY CEILING tripped after \(MutefySettings.maxMuteSeconds)s — detection failed mid-ad")
        }

        if changed {
            if stateMachine.isAd {
                enterAd()
            } else {
                leaveAd()
            }
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

    private func enterAd() {
        if restartToSkipAdsEnabled {
            mutefyLog("ad detected — restarting Spotify to skip")
            restartSpotify()
            return
        }

        guard !muted else { return }

        guard let current = getSpotifyVolume() else {
            mutefyLog("ad detected but Spotify volume unreadable — not muting")
            return
        }

        // Spotify was already silent before we touched it; leave it alone rather than
        // surprising the user with sound when the ad ends.
        if current == 0 {
            mutefyLog("ad detected, Spotify already at 0 — leaving it to the user")
            muted = true
            spotifyUserVolume = 0
            titleChangeHandler(.ad)
            return
        }

        spotifyUserVolume = current
        // Persisted before the mute, not after: a crash between the two must leave a
        // recoverable value behind.
        MutefySettings.savedSpotifyVolume = current
        setSpotifyVolume(volume: 0)
        muted = true
        titleChangeHandler(.ad)
        mutefyLog("AD START — muted Spotify (was \(current))")

        filler.start()
    }

    private func leaveAd() {
        guard muted else { return }

        // Don't fight a manual volume change: if the user raised it during the ad, that is
        // now their volume and restoring ours would undo their choice.
        if let current = getSpotifyVolume(), current == 0, spotifyUserVolume != 0 {
            setSpotifyVolume(volume: spotifyUserVolume)
            mutefyLog("AD END — restored Spotify volume to \(spotifyUserVolume)")
        } else {
            mutefyLog("AD END — user changed volume during the ad, leaving it alone")
        }

        muted = false
        MutefySettings.savedSpotifyVolume = -1
        titleChangeHandler(.noAd)

        filler.stop()
    }

    /// Classifies one AppleScript reading.
    ///
    /// `unknown` matters: when Spotify is not running or the bridge returns nothing, that is
    /// not evidence the ad ended. Treating it as "not an ad" would unmute mid-break every
    /// time a query hiccupped.
    private func readAd() -> AdReading {
        let url = getCurrentSongSpotifyURL().trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return .unknown }
        return url.starts(with: "spotify:ad") ? .ad : .notAd
    }

    /// One-line summary of what Spotify says right now, for the log. Kept off the hot path —
    /// only called when a reading changes, not on every poll.
    private func describeCurrentTrack() -> String {
        let url = getCurrentSongSpotifyURL().trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            return "no reply from Spotify — not running, or Automation permission refused"
        }
        let volume = getSpotifyVolume().map(String.init) ?? "?"
        return "url=\(url) volume=\(volume)"
    }

    /// Starts the fallback poll. See `pollTimer`.
    func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: evaluationQueue)
        timer.schedule(deadline: .now() + SpotifyManager.pollInterval,
                       repeating: SpotifyManager.pollInterval)
        timer.setEventHandler { [weak self] in
            _ = self?.evaluate()
        }
        timer.resume()
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Restores Spotify's volume if a previous run died during an ad.
    ///
    /// The app this forks from kept the pre-mute volume in memory only, so a force-quit
    /// mid-ad left Spotify permanently silent with nothing able to put it back. Runs at
    /// launch regardless of whether ad muting is currently enabled.
    func recoverStaleMuteIfNeeded() {
        let saved = MutefySettings.savedSpotifyVolume
        guard saved > 0 else { return }

        MutefySettings.savedSpotifyVolume = -1

        guard let current = getSpotifyVolume() else { return }
        guard current == 0 else {
            mutefyLog("stale mute record found (\(saved)) but Spotify is at \(current) — nothing to do")
            return
        }

        setSpotifyVolume(volume: saved)
        mutefyLog("RECOVERED — previous run died during an ad, restored Spotify volume to \(saved)")
    }

    /// Puts Spotify's volume back on the way out.
    ///
    /// Quitting during an ad must not leave Spotify silent. Unlike the Windows build, where
    /// the mute died with the process, here it is a value written into Spotify itself and
    /// survives us.
    func restoreVolumeBeforeQuitting() {
        // Cancelling does not wait for a handler already running, and this is called from the
        // main thread while the poll may be halfway through enterAd(). Going through the same
        // serial queue makes us queue behind it instead of reading `muted` mid-update — which
        // on this path would mean quitting without restoring.
        stopPolling()

        evaluationQueue.sync {
            guard muted, spotifyUserVolume > 0 else {
                MutefySettings.savedSpotifyVolume = -1
                return
            }

            setSpotifyVolume(volume: spotifyUserVolume)
            muted = false
            MutefySettings.savedSpotifyVolume = -1
            mutefyLog("quitting during an ad — restored Spotify volume to \(spotifyUserVolume)")
        }
    }

    /// Rebuilds the state machine after the user changes debounce or ceiling settings.
    func applySettings() {
        evaluationQueue.sync {
            stateMachine = AdStateMachine(
                enterDebounce: Double(MutefySettings.adEnterDebounceMs) / 1000.0,
                maxAdDuration: Double(MutefySettings.maxMuteSeconds))
            mutefyLog("settings applied — debounce \(MutefySettings.adEnterDebounceMs)ms, ceiling \(MutefySettings.maxMuteSeconds)s")
        }
    }
    
    func setSpotifyVolume(volume: Int) {
        _ = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "set sound volume to \(volume)")

        // Read back and complain if it did not take. Spotify stores the volume with a little
        // loss — asking for 94 reads back 93, 90 reads back 89 — so only a real disagreement
        // is worth logging. This exists because "Spotify was left silent" is the one failure
        // the user cannot diagnose from the outside, and a write that silently did nothing
        // would look identical to one that was never attempted.
        guard let actual = getSpotifyVolume() else {
            mutefyLog("volume write of \(volume) could not be confirmed — Spotify did not answer")
            return
        }
        if abs(actual - volume) > 2 {
            mutefyLog("volume write MISMATCH: asked for \(volume), Spotify reports \(actual)")
        }
    }
    
    /**
     * Gets current spotify volume, or nil when Spotify could not be asked.
     *
     * Returns an optional rather than crashing: the original force-unwrapped both the split
     * and the Int conversion, so an empty reply — which is what you get when Spotify is not
     * running — took the whole app down with an index-out-of-range.
     */
    func getSpotifyVolume() -> Int? {
        let reply = runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "(get sound volume)")
        guard let firstLine = reply.split(separator: "\n").first else { return nil }
        return Int(firstLine.trimmingCharacters(in: .whitespaces))
    }
    
    /**
     * Checks whether an ad is currently playing
     *
     * This is done by checking the spoify url's prifix
     */
    func isSpotifyAdPlaying() -> Bool {
        let spotifyURL = getCurrentSongSpotifyURL()
        return spotifyURL.starts(with: "spotify:ad")
    }
    
    func getCurrentSongSpotifyURL() -> String {
        return runAppleScript(script: SpotifyManager.appleScriptSpotifyPrefix + "(get spotify url of current track)")
    }

    func captureFocusRestoreTarget() {
        let capture = {
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
                  let frontmostBundleIdentifier = frontmostApp.bundleIdentifier else {
                self.focusRestoreBundleIdentifier = nil
                return
            }

            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            if frontmostBundleIdentifier == "com.spotify.client" || frontmostBundleIdentifier == ownBundleIdentifier {
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
            if currentFrontmostBundleIdentifier != "com.spotify.client" && currentFrontmostBundleIdentifier != ownBundleIdentifier {
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
     * Runs the given apple script and passes logs to completion handler
     */
    func runAppleScript(script: String) -> String {
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        // stderr is discarded deliberately: osascript writes permission and
        // "application isn't running" errors there, and an empty stdout already carries
        // that meaning for every caller here.
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            mutefyLog("osascript failed to launch: \(error.localizedDescription)")
            return ""
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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
