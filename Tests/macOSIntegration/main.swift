import AppKit
import AVFoundation
import Foundation

setbuf(stdout, nil)

// Keep integration-test diagnostics separate from the running app's log.
func mutefyLog(_ message: String) { print("  \(message)") }
final class MutefyLog {
    static let shared = MutefyLog()
    let path = "/dev/null"
}

final class MockSpotify: SpotifyManager {
    var url = "spotify:track:test"
    var volume: Int? = 73
    var volumeWrites: [Int] = []

    override func runAppleScript(script: String) -> String {
        if script.contains("get spotify url") { return url }
        if script.contains("get sound volume") { return volume.map(String.init) ?? "" }
        if let range = script.range(of: "set sound volume to "),
           let requested = Int(script[range.upperBound...]) {
            volumeWrites.append(requested)
            volume = requested
        }
        return ""
    }
}

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}

func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

// A separate executable has its own defaults domain. Never touch com.countnine.mutefy.
let testDomain = ProcessInfo.processInfo.processName
precondition(testDomain == "MutefyIntegrationTests")
UserDefaults.standard.removePersistentDomain(forName: testDomain)
defer { UserDefaults.standard.removePersistentDomain(forName: testDomain) }
MutefySettings.adEnterDebounceMs = 0
MutefySettings.fillerEnabled = false

let spotify = MockSpotify(titleChangeHandler: { _ in })
spotify.url = "spotify:ad:test"
check(spotify.handleTrackChanged() && spotify.volume == 0, "ad mutes Spotify")
check(MutefySettings.savedSpotifyVolume == 73, "pre-mute volume is persisted")
spotify.url = ""
check(!spotify.handleTrackChanged() && spotify.volume == 0, "unknown reading holds mute")
spotify.url = "spotify:track:test"
check(spotify.handleTrackChanged() && spotify.volume == 73, "music restores volume")
check(MutefySettings.savedSpotifyVolume == -1, "restoration clears recovery record")

spotify.url = "spotify:ad:test"
spotify.handleTrackChanged()
spotify.volume = 41
spotify.url = "spotify:track:test"
spotify.handleTrackChanged()
check(spotify.volume == 41, "user volume change during ad is preserved")

spotify.volume = 0
spotify.url = "spotify:ad:test"
spotify.handleTrackChanged()
spotify.url = "spotify:track:test"
spotify.handleTrackChanged()
check(spotify.volume == 0, "pre-existing mute stays muted")

spotify.volume = nil
spotify.url = "spotify:ad:test"
let writesBefore = spotify.volumeWrites.count
spotify.handleTrackChanged()
check(spotify.volumeWrites.count == writesBefore && !spotify.muted,
      "unreadable volume does not trigger a mute")
spotify.url = "spotify:track:test"
spotify.handleTrackChanged()

spotify.volume = 0
MutefySettings.savedSpotifyVolume = 66
spotify.recoverStaleMuteIfNeeded()
check(spotify.volume == 66 && MutefySettings.savedSpotifyVolume == -1,
      "launch recovers volume after a crash")
spotify.url = "spotify:ad:test"
spotify.handleTrackChanged()
spotify.restoreVolumeBeforeQuitting()
check(spotify.volume == 66 && MutefySettings.savedSpotifyVolume == -1,
      "quitting during ad restores volume")

let model = MutefySettingsModel()
model.restartToSkipAds = true
model.fillerEnabled = true
check(!model.restartToSkipAds && !UserDefaults.standard.bool(forKey: MutefySettings.Key.restartToSkipAds),
      "enabling filler disables restart mode")
model.restartToSkipAds = true
check(!model.fillerEnabled && !MutefySettings.fillerEnabled,
      "enabling restart mode disables filler")
MutefySettings.fillerVolumePercent = 200
MutefySettings.maxMuteSeconds = 0
check(MutefySettings.fillerVolumePercent == 100 && MutefySettings.maxMuteSeconds == 10,
      "invalid settings are clamped")

// Exercise actual folder enumeration, AVAudioPlayer and its fade teardown with silence.
let folder = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("music")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let wav = folder.appendingPathComponent("silence.wav")
let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 40_000)!
buffer.frameLength = 40_000
buffer.floatChannelData![0].initialize(repeating: 0, count: 40_000)
do {
    let file = try AVAudioFile(forWriting: wav, settings: format.settings)
    try file.write(from: buffer)
}
MutefySettings.fillerFolderPath = folder.path
MutefySettings.fillerEnabled = true
MutefySettings.fillerStartDelayMs = 0
MutefySettings.fillerFadeInMs = 20
MutefySettings.fillerFadeOutMs = 20
MutefySettings.fillerVolumePercent = 0
let filler = FillerPlayer()
filler.warmUp()
check(spin { filler.playableFileCount() == 1 }, "folder scan finds generated WAV")
filler.start()
check(spin { _ = filler.playableFileCount(); return filler.nowPlaying != nil },
      "AVAudioPlayer starts filler")
filler.stop()
check(spin { _ = filler.playableFileCount(); return filler.nowPlaying == nil },
      "fade-out tears down filler")
print("All macOS integration checks passed.")
