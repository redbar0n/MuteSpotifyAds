//
//  SettingsWindowController.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//

import AppKit
import SwiftUI

/// Backing store for the settings window.
///
/// Values write straight through to `MutefySettings` on change and then tell the app what to
/// re-read, so there is no Apply button and no chance of the window and the running app
/// disagreeing.
final class MutefySettingsModel: ObservableObject {

    /// Called when a filler value changed (folder, volume, fades).
    var onFillerChanged: ((_ folderChanged: Bool) -> Void)?
    /// Called when the debounce or safety ceiling changed.
    var onAdvancedChanged: (() -> Void)?
    /// Called when the filler/restart exclusivity flipped, so the status menu can re-tick.
    var onExclusivityChanged: (() -> Void)?

    /// Suppresses write-through while the initialiser populates the published properties.
    private var loading = true

    @Published var fillerEnabled: Bool {
        didSet {
            guard !loading else { return }
            MutefySettings.fillerEnabled = fillerEnabled
            // Restarting Spotify skips the ad outright, which leaves the filler nothing to
            // cover. Only one of the two can be in charge of an ad break.
            if fillerEnabled && restartToSkipAds { restartToSkipAds = false }
            onExclusivityChanged?()
        }
    }

    @Published var restartToSkipAds: Bool {
        didSet {
            guard !loading else { return }
            MutefySettings.set(restartToSkipAds, forKey: MutefySettings.Key.restartToSkipAds)
            if restartToSkipAds && fillerEnabled { fillerEnabled = false }
            onExclusivityChanged?()
        }
    }

    @Published var folderPath: String {
        didSet {
            guard !loading else { return }
            MutefySettings.fillerFolderPath = folderPath
            onFillerChanged?(true)
        }
    }

    @Published var recursive: Bool {
        didSet {
            guard !loading else { return }
            MutefySettings.fillerRecursive = recursive
            onFillerChanged?(true)
        }
    }

    @Published var volumePercent: Double {
        didSet {
            guard !loading else { return }
            MutefySettings.fillerVolumePercent = Int(volumePercent)
            onFillerChanged?(false)
        }
    }

    @Published var fadeInMs: Double {
        didSet {
            guard !loading else { return }
            MutefySettings.fillerFadeInMs = Int(fadeInMs)
        }
    }

    @Published var fadeOutMs: Double {
        didSet {
            guard !loading else { return }
            MutefySettings.fillerFadeOutMs = Int(fadeOutMs)
        }
    }

    @Published var startDelayMs: Double {
        didSet {
            guard !loading else { return }
            MutefySettings.fillerStartDelayMs = Int(startDelayMs)
        }
    }

    @Published var maxMuteSeconds: Double {
        didSet {
            guard !loading else { return }
            MutefySettings.maxMuteSeconds = Int(maxMuteSeconds)
            onAdvancedChanged?()
        }
    }

    @Published var adEnterDebounceMs: Double {
        didSet {
            guard !loading else { return }
            MutefySettings.adEnterDebounceMs = Int(adEnterDebounceMs)
            onAdvancedChanged?()
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !loading else { return }
            if !LaunchAtLogin.set(launchAtLogin) {
                // Registration can be refused; show what actually happened.
                loading = true
                launchAtLogin = LaunchAtLogin.isEnabled
                loading = false
            }
        }
    }

    /// Number of playable files found, shown so an empty or wrong folder is obvious before
    /// the next ad rather than after it.
    @Published var playableCount: Int = 0

    init() {
        fillerEnabled = MutefySettings.fillerEnabled
        restartToSkipAds = UserDefaults.standard.bool(forKey: MutefySettings.Key.restartToSkipAds)
        folderPath = MutefySettings.fillerFolderPath
        recursive = MutefySettings.fillerRecursive
        volumePercent = Double(MutefySettings.fillerVolumePercent)
        fadeInMs = Double(MutefySettings.fillerFadeInMs)
        fadeOutMs = Double(MutefySettings.fillerFadeOutMs)
        startDelayMs = Double(MutefySettings.fillerStartDelayMs)
        maxMuteSeconds = Double(MutefySettings.maxMuteSeconds)
        adEnterDebounceMs = Double(MutefySettings.adEnterDebounceMs)
        launchAtLogin = LaunchAtLogin.isEnabled
        loading = false
    }

    /// Re-reads everything without triggering write-through. Used when the status menu
    /// changes a value the window also shows, so the two cannot drift apart.
    func reloadFromDefaults() {
        loading = true
        fillerEnabled = MutefySettings.fillerEnabled
        restartToSkipAds = UserDefaults.standard.bool(forKey: MutefySettings.Key.restartToSkipAds)
        folderPath = MutefySettings.fillerFolderPath
        recursive = MutefySettings.fillerRecursive
        volumePercent = Double(MutefySettings.fillerVolumePercent)
        fadeInMs = Double(MutefySettings.fillerFadeInMs)
        fadeOutMs = Double(MutefySettings.fillerFadeOutMs)
        startDelayMs = Double(MutefySettings.fillerStartDelayMs)
        maxMuteSeconds = Double(MutefySettings.maxMuteSeconds)
        adEnterDebounceMs = Double(MutefySettings.adEnterDebounceMs)
        launchAtLogin = LaunchAtLogin.isEnabled
        loading = false
    }
}

struct SettingsView: View {

    @ObservedObject var model: MutefySettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                section(NSLocalizedString("Filler music", comment: ""))

                Toggle(NSLocalizedString("Play music from a folder while an ad is muted", comment: ""),
                       isOn: $model.fillerEnabled)

                Text(NSLocalizedString("A measured ad break ran 56 seconds. This fills that stretch with your own music instead of silence.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(NSLocalizedString("Folder:", comment: ""))
                    Text(model.folderPath.isEmpty
                         ? NSLocalizedString("(none selected)", comment: "")
                         : model.folderPath)
                        .font(.caption)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    Button(NSLocalizedString("Choose…", comment: "")) { chooseFolder() }
                }

                Toggle(NSLocalizedString("Include subfolders", comment: ""), isOn: $model.recursive)

                Text(String(format: NSLocalizedString("%d playable file(s) found", comment: ""), model.playableCount))
                    .font(.caption)
                    .foregroundColor(model.playableCount == 0 && !model.folderPath.isEmpty ? .red : .secondary)

                slider(NSLocalizedString("Volume", comment: ""),
                       value: $model.volumePercent, range: 0...100, unit: "%")
                slider(NSLocalizedString("Fade in", comment: ""),
                       value: $model.fadeInMs, range: 0...5000, unit: "ms")
                slider(NSLocalizedString("Fade out", comment: ""),
                       value: $model.fadeOutMs, range: 0...8000, unit: "ms")
                slider(NSLocalizedString("Start delay", comment: ""),
                       value: $model.startDelayMs, range: 0...5000, unit: "ms")

                Divider()

                section(NSLocalizedString("Skipping", comment: ""))

                Toggle(NSLocalizedString("Restart Spotify to skip ads instead of muting", comment: ""),
                       isOn: $model.restartToSkipAds)

                Text(NSLocalizedString("Skipping and filler music cannot both be on: restarting removes the ad the filler would cover.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                section(NSLocalizedString("Advanced", comment: ""))

                slider(NSLocalizedString("Safety ceiling", comment: ""),
                       value: $model.maxMuteSeconds, range: 10...600, unit: "s")
                Text(NSLocalizedString("Force the volume back if detection fails during an ad. Must comfortably exceed a full ad break.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                slider(NSLocalizedString("Entry debounce", comment: ""),
                       value: $model.adEnterDebounceMs, range: 0...3000, unit: "ms")
                Text(NSLocalizedString("How long an ad verdict must hold before muting. Leaving an ad is never debounced.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if LaunchAtLogin.isSupported {
                    Divider()
                    Toggle(NSLocalizedString("Open at login", comment: ""), isOn: $model.launchAtLogin)
                }

                Divider()

                HStack {
                    Button(NSLocalizedString("Reveal log file", comment: "")) {
                        NSWorkspace.shared.selectFile(MutefyLog.shared.path,
                                                      inFileViewerRootedAtPath: "")
                    }
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 460, height: 620)
        .onAppear { model.playableCount = SettingsWindowController.filler?.playableFileCount() ?? 0 }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))\(unit)")
                .font(.caption)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Choose the folder to play from while ads are muted.", comment: "")

        if panel.runModal() == .OK, let path = panel.url?.path {
            model.folderPath = path
            model.playableCount = SettingsWindowController.filler?.playableFileCount() ?? 0
        }
    }
}

/// Owns the settings window. A single instance is reused so reopening from the menu brings
/// the existing window forward instead of stacking duplicates.
final class SettingsWindowController: NSWindowController {

    /// Set once at launch so the view can count playable files without threading a
    /// reference through every initialiser.
    static weak var filler: FillerPlayer?

    private static var shared: SettingsWindowController?

    static func show(model: MutefySettingsModel) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = NSLocalizedString("Mutefy Settings", comment: "")
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.center()
        window.isReleasedWhenClosed = false

        let controller = SettingsWindowController(window: window)
        shared = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
