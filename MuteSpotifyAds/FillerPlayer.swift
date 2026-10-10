//
//  FillerPlayer.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//
//  Behaviour ported from the Windows build of Mutefy (src/Mutefy.Core/FillerPlayer.cs +
//  FadeSampleProvider.cs), which is also GPL-3.0. The implementation is much smaller here:
//  AVAudioPlayer fades natively, and because Mutefy lowers *Spotify's own* volume rather
//  than the system's, the filler is unaffected by the mute for free. On Windows that
//  separation had to be built by hand with a dedicated WASAPI session.
//

import AVFoundation
import Foundation

/// Fills the muted stretch with music from a folder of the user's own, instead of leaving
/// the better part of a minute of silence. A measured ad break ran 56 seconds.
final class FillerPlayer: NSObject, AVAudioPlayerDelegate {

    private static let supportedExtensions: Set<String> =
        ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac"]

    /// How long a folder listing is trusted before being re-read.
    ///
    /// Ten minutes, not one: pointing this at `~/Music` on a Mac with an Apple Music library
    /// measured **50 seconds** to enumerate, so a one-minute cache would expire before it was
    /// ever used and every ad would pay for the walk again. Folder changes invalidate the
    /// cache explicitly anyway, so the timer only exists to notice files added behind our back.
    private static let rescanAfter: TimeInterval = 600

    private let queue = DispatchQueue(label: "com.countnine.mutefy.filler")

    /// Scans run here so a slow one cannot hold up start/stop on `queue`.
    private let scanQueue = DispatchQueue(label: "com.countnine.mutefy.filler.scan", qos: .utility)
    private var scanning = false

    private var player: AVAudioPlayer?

    // Shuffle bag: files are drawn without replacement and the bag is refilled once empty,
    // so nothing repeats until the folder has been exhausted.
    private var bag: [String] = []
    private var files: [String] = []
    private var scannedFolder: String?
    private var scannedAt: Date = .distantPast

    /// Invalidates scheduled work (start delays, fade-out teardowns) when state moves on.
    private var generation = 0
    private var fadingOut = false

    /// Raised when playback could not start, so the presentation layer owns the wording.
    var onFailure: ((String) -> Void)?

    /// Path of the file currently playing, or nil.
    private(set) var nowPlaying: String?

    // MARK: - Lifecycle

    /// Called when an ad starts. Honours the configured start delay so a momentary false
    /// positive does not produce an audible blip.
    func start() {
        guard MutefySettings.fillerEnabled else { return }
        let folder = MutefySettings.fillerFolderPath
        guard !folder.isEmpty else { return }

        let fadeIn = Double(max(1, MutefySettings.fillerFadeInMs)) / 1000.0
        let delay = Double(MutefySettings.fillerStartDelayMs) / 1000.0

        queue.async {
            // Ad B started while ad A's fade-out was still running: cancel the teardown and
            // fade the same track back in rather than restarting from silence.
            if let player = self.player, self.fadingOut {
                self.generation += 1
                self.fadingOut = false
                player.setVolume(self.targetVolume(), fadeDuration: fadeIn)
                mutefyLog("filler: fade-out cancelled, resuming '\(self.nowPlaying ?? "?")'")
                return
            }

            if self.player != nil { return }

            self.generation += 1
            let generation = self.generation

            self.queue.asyncAfter(deadline: .now() + delay) {
                guard self.generation == generation else { return }
                self.playNext(generation: generation)
            }
        }
    }

    /// Called when the ad ends. Fades out, then tears down.
    func stop() {
        let fadeOut = Double(max(1, MutefySettings.fillerFadeOutMs)) / 1000.0

        queue.async {
            guard let player = self.player else { return }
            if self.fadingOut { return }

            self.generation += 1
            let generation = self.generation
            self.fadingOut = true

            player.setVolume(0, fadeDuration: fadeOut)
            mutefyLog("filler: fading out over \(Int(fadeOut * 1000))ms")

            // A small tail past the fade so the last of it is actually heard before the
            // player goes away.
            self.queue.asyncAfter(deadline: .now() + fadeOut + 0.1) {
                // start() bumped the generation — the fade-out was cancelled, keep playing.
                guard self.generation == generation else { return }
                self.teardown()
            }
        }
    }

    /// Stops immediately with no fade. For app teardown, where nobody is listening anyway.
    func stopImmediately() {
        queue.async {
            self.generation += 1
            self.teardown()
        }
    }

    // MARK: - Settings changes

    /// Applies a volume change from the settings window without restarting playback.
    func refreshVolume() {
        queue.async {
            self.player?.volume = self.targetVolume()
        }
    }

    /// Forgets the cached folder listing, e.g. after the folder setting changes, and starts
    /// building the new one straight away rather than leaving the next ad to pay for it.
    func invalidateFolderCache() {
        queue.async {
            self.scannedFolder = nil
            self.scannedAt = .distantPast
            self.files = []
            self.bag.removeAll()
            self.ensureScanned()
        }
    }

    /// Number of playable files found so far, for the settings window.
    ///
    /// Deliberately does not wait for a scan: this is called from the main thread as the
    /// window appears, and a cold `~/Music` takes tens of seconds to walk. The count arrives
    /// via `onCountChanged` when it is known.
    func playableFileCount() -> Int {
        queue.sync { files.count }
    }

    /// Called on the main thread whenever the file list changes, so the settings window can
    /// show a count it did not have to block for.
    var onCountChanged: ((Int) -> Void)?

    // MARK: - Playback

    private func playNext(generation: Int) {
        guard self.generation == generation else { return }

        ensureScanned()

        guard let path = takeFromBag() else {
            let folder = MutefySettings.fillerFolderPath
            if scanning {
                // Distinguished from a genuinely empty folder because the fix is different:
                // wait versus pick a different folder.
                mutefyLog("filler: nothing to play yet — still scanning '\(folder)'")
            } else {
                mutefyLog("filler: no playable files in '\(folder)'")
                DispatchQueue.main.async { self.onFailure?(folder) }
            }
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.delegate = self
            // Start silent and fade up, so the buffer that is already queued when playback
            // begins cannot leak a burst at full volume.
            player.volume = 0
            player.prepareToPlay()
            player.play()
            player.setVolume(targetVolume(), fadeDuration: Double(max(1, MutefySettings.fillerFadeInMs)) / 1000.0)

            self.player = player
            self.fadingOut = false
            self.nowPlaying = path
            mutefyLog("filler: playing '\((path as NSString).lastPathComponent)' at \(MutefySettings.fillerVolumePercent)%")
        } catch {
            mutefyLog("filler: cannot play '\(path)' — \(error.localizedDescription)")
            // One bad file should not mean silence; try the next one.
            if !bag.isEmpty { playNext(generation: generation) }
        }
    }

    /// A track that ends before the ad does must hand over to the next one, or silence
    /// returns halfway through the break.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        queue.async {
            guard self.player === player, !self.fadingOut else { return }
            let generation = self.generation
            self.player = nil
            self.nowPlaying = nil
            self.playNext(generation: generation)
        }
    }

    private func teardown() {
        guard let player = player else { return }
        player.stop()
        self.player = nil
        self.fadingOut = false
        mutefyLog("filler: stopped '\((nowPlaying.map { ($0 as NSString).lastPathComponent }) ?? "?")'")
        nowPlaying = nil
    }

    private func targetVolume() -> Float {
        Float(MutefySettings.fillerVolumePercent) / 100.0
    }

    // MARK: - Folder scanning

    /// Populates the file list ahead of time, so the first ad does not pay for the walk.
    /// Called at launch and after the folder setting changes.
    func warmUp() {
        queue.async { self.ensureScanned() }
    }

    /// Makes sure a scan is either current or under way. **Never scans inline.**
    ///
    /// Pointing the filler at `~/Music` on a Mac with an Apple Music library took over two
    /// minutes to enumerate. Any scan on this queue would hold up `start()` and `stop()`
    /// behind it, so the filler would miss the break it was supposed to cover — which is
    /// exactly what happened before this was split out. A cold cache means the first ad goes
    /// uncovered; that is the honest trade, and it is why the list is built at launch.
    private func ensureScanned() {
        let folder = MutefySettings.fillerFolderPath
        guard !folder.isEmpty else {
            files = []
            bag = []
            scannedFolder = nil
            return
        }

        let sameFolder = folder == scannedFolder
        if sameFolder && Date().timeIntervalSince(scannedAt) < FillerPlayer.rescanAfter { return }

        scheduleRescan(folder)
    }

    private func scheduleRescan(_ folder: String) {
        guard !scanning else { return }
        scanning = true

        scanQueue.async {
            let found = self.scan(folder)
            self.queue.async {
                self.scanning = false
                guard MutefySettings.fillerFolderPath == folder else {
                    // The folder changed while we walked the old one, so this result is
                    // useless — and the new folder's scan was skipped because this one was
                    // already running. Start it now rather than waiting for an ad to notice.
                    self.ensureScanned()
                    return
                }
                self.install(found, for: folder)
            }
        }
    }

    /// Give up on a folder walk after this long. `~/Music` with an Apple Music library
    /// exceeded two minutes; a shuffle bag does not get better for having every last file in
    /// it, and a scan that never ends is a scan that never produces a list.
    private static let scanTimeLimit: TimeInterval = 20

    /// And after this many files, for the same reason.
    private static let scanFileLimit = 5_000

    /// Pure enumeration, bounded. Runs on `scanQueue`.
    private func scan(_ folder: String) -> [String] {
        let start = Date()
        var found: [String] = []
        var truncated: String?
        let manager = FileManager.default
        let root = URL(fileURLWithPath: folder)
        let options: FileManager.DirectoryEnumerationOptions =
            MutefySettings.fillerRecursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]

        if let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: options) {
            while let url = enumerator.nextObject() as? URL {
                if FillerPlayer.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(url.path)
                    if found.count >= FillerPlayer.scanFileLimit {
                        truncated = "hit the \(FillerPlayer.scanFileLimit) file limit"
                        break
                    }
                }

                // The clock is checked every entry, not every N. `nextObject()` on this
                // machine spends its time in `open()` per directory — a few entries a second
                // on ~/Music — so a batched check would let a "20 second" limit run for
                // minutes, which is the bug this limit exists to prevent.
                if Date().timeIntervalSince(start) > FillerPlayer.scanTimeLimit {
                    truncated = String(format: "gave up after %.0fs", FillerPlayer.scanTimeLimit)
                    break
                }
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        // Logged with the duration, and never truncated silently: a folder that only yielded
        // part of its contents would otherwise look identical to one that yielded all of them.
        if let truncated = truncated {
            mutefyLog(String(format: "filler: scanned '%@' in %.1fs — %d playable (INCOMPLETE, %@)",
                             folder, elapsed, found.count, truncated))
        } else {
            mutefyLog(String(format: "filler: scanned '%@' in %.1fs — %d playable",
                             folder, elapsed, found.count))
        }
        return found
    }

    private func install(_ found: [String], for folder: String) {
        files = found.sorted()
        scannedFolder = folder
        scannedAt = Date()

        // A changed listing invalidates the bag; drawing from a stale one could hand back a
        // path that no longer exists.
        bag.removeAll()

        let count = files.count
        DispatchQueue.main.async { self.onCountChanged?(count) }
    }

    private func takeFromBag() -> String? {
        if files.isEmpty { return nil }
        if bag.isEmpty { bag = files.shuffled() }
        return bag.popLast()
    }
}
