//
//  AppDelegate.swift
//  MuteSpotifyAds
//
//  Created by Simon Meusel on 25.05.18.
//  Copyright © 2019 Simon Meusel. All rights reserved.
//

import Cocoa
import Foundation
import UserNotifications
import UniformTypeIdentifiers

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let endlessPrivateSessionKey = "EndlessPrivateSession"
    let restartToSkipAdsKey = "RestartToSkipAds"
    let startSpotifyKey = "StartSpotify"
    let notificationsKey = "Notifications"
    let songLogPathKey = "SongLogPath"
    
    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var titleMenuItem: NSMenuItem!
    @IBOutlet weak var endlessPrivateSessionCheckbox: NSMenuItem!
    @IBOutlet weak var restartToSkipAdsCheckbox: NSMenuItem!
    @IBOutlet weak var startSpotifyCheckbox: NSMenuItem!
    @IBOutlet weak var notificationsCheckbox: NSMenuItem!
    @IBOutlet weak var songLogCheckbox: NSMenuItem!
    
    var notificationsEnabled = false
    
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var spotifyManager: SpotifyManager?
    let settingsModel = MutefySettingsModel()
    
    @IBAction func quit(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }

    @IBAction func quitWithSotify(_ sender: Any) {
        spotifyManager?.quitSpotify()
        quit(sender);
    }
    
    @IBAction func openProjectWebsite(_ sender: Any) {
        openWebsite(url: "https://github.com/countnine/MuteSpotifyAds")
    }
    
    @IBAction func openReportBugWebsite(_ sender: Any) {
        openWebsite(url: "https://github.com/countnine/MuteSpotifyAds/issues")
    }
    
    
    @IBAction func openLicenseWebsite(_ sender: Any) {
        openWebsite(url: "https://www.gnu.org/licenses/gpl-3.0.txt")
    }
    
    @IBAction func toggleEndlessPrivateSession(_ sender: NSMenuItem) {
        if spotifyManager!.endlessPrivateSessionEnabled {
            spotifyManager?.endlessPrivateSessionEnabled = false
            spotifyManager?.disablePrivateSession()
            sender.state = .off
        } else {
            spotifyManager?.endlessPrivateSessionEnabled = true
            spotifyManager?.enablePrivateSession()
            sender.state = .on
        }
        UserDefaults.standard.set(spotifyManager?.endlessPrivateSessionEnabled, forKey: endlessPrivateSessionKey)
    }
    
    @IBAction func toggleRestartToSkipAds(_ sender: NSMenuItem) {
        if spotifyManager!.restartToSkipAdsEnabled {
            spotifyManager?.restartToSkipAdsEnabled = false
            sender.state = .off
        } else {
            spotifyManager?.restartToSkipAdsEnabled = true
            sender.state = .on

            // Skipping removes the ad the filler exists to cover, so the two are exclusive.
            // Switching this on from the menu has to turn the filler off, exactly as the
            // settings window does in the other direction.
            if MutefySettings.fillerEnabled {
                MutefySettings.fillerEnabled = false
                settingsModel.reloadFromDefaults()
                mutefyLog("filler disabled — 'restart to skip ads' was switched on")
            }
        }
        UserDefaults.standard.set(spotifyManager?.restartToSkipAdsEnabled, forKey: restartToSkipAdsKey)
        settingsModel.reloadFromDefaults()
    }
    
    @IBAction func toggleNotifications(_ sender: NSMenuItem) {
        if notificationsEnabled {
            notificationsEnabled = false
            sender.state = .off
        } else {
            notificationsEnabled = true
            sender.state = .on
        }
        UserDefaults.standard.set(notificationsEnabled, forKey: notificationsKey)
    }
    
    @IBAction func toggleSpotifyStart(_ sender: NSMenuItem) {
        if spotifyManager!.startSpotify {
            spotifyManager?.startSpotify = false
            sender.state = .off
        } else {
            spotifyManager?.startSpotify = true
            sender.state = .on
        }
        UserDefaults.standard.set(spotifyManager?.startSpotify, forKey: startSpotifyKey)
    }
    
    @IBAction func toggleSongLog(_ sender: NSMenuItem) {
        if spotifyManager?.songLogPath != nil {
            spotifyManager?.songLogPath = nil
            sender.state = .off
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.allowsOtherFileTypes = true
            panel.canCreateDirectories = true
            panel.canSelectHiddenExtension = true
            panel.showsTagField = false
            panel.message = "The song log file will contain a entry for each song you listen.\nSelect where the .csv file should be saved on disk."
            panel.titleVisibility = .visible
            let result = panel.runModal()
            if result == .OK {
                spotifyManager?.songLogPath = panel.url?.path
                sender.state = .on
            } else {
                spotifyManager?.songLogPath = nil
            }
        }
        UserDefaults.standard.set(spotifyManager?.songLogPath, forKey: songLogPathKey)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        configureNotifications()
        
        // Defer all status bar UI setup to avoid layout recursion during
        // AppKit's initial menu bar layout pass.
        let version = Bundle.main.infoDictionary!["CFBundleShortVersionString"]!
        DispatchQueue.main.async {
            self.statusItem.menu = self.statusMenu
            self.setStatusBarTitle(title: .noAd)
            self.titleMenuItem.title = self.titleMenuItem.title + " v\(version)"
        }
        
        print("Mutefy v\(version)")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        
        spotifyManager = SpotifyManager(titleChangeHandler: {
            title in
            DispatchQueue.main.async {
                self.setStatusBarTitle(title: title)
            }
        })
        
        if UserDefaults.standard.bool(forKey: endlessPrivateSessionKey) {
            spotifyManager?.enablePrivateSession()
            spotifyManager?.endlessPrivateSessionEnabled = true
            endlessPrivateSessionCheckbox.state = .on
        }
        
        if UserDefaults.standard.bool(forKey: restartToSkipAdsKey) {
            spotifyManager?.restartToSkipAdsEnabled = true
            restartToSkipAdsCheckbox.state = .on
        }
        
        if UserDefaults.standard.object(forKey: startSpotifyKey) == nil {
            UserDefaults.standard.set(true, forKey: startSpotifyKey)
        }
        if UserDefaults.standard.bool(forKey: startSpotifyKey) {
            spotifyManager?.startSpotify = true
            startSpotifyCheckbox.state = .on
        }
        
        if UserDefaults.standard.object(forKey: notificationsKey) == nil {
            UserDefaults.standard.set(true, forKey: notificationsKey)
        }
        if UserDefaults.standard.bool(forKey: notificationsKey) {
            notificationsEnabled = true
            notificationsCheckbox.state = .on
        }
        
        spotifyManager?.songLogPath = UserDefaults.standard.string(forKey: songLogPathKey)
        if spotifyManager?.songLogPath != nil {
            songLogCheckbox.state = .on
        }

        configureMutefy()

        spotifyManager?.startWatchingForFileChanges()
    }

    // MARK: - Mutefy

    /// Wires up everything Mutefy adds on top of MuteSpotifyAds.
    private func configureMutefy() {
        guard let spotifyManager = spotifyManager else { return }

        mutefyLog("=== Mutefy \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ===")

        SettingsWindowController.filler = spotifyManager.filler

        spotifyManager.filler.onFailure = { [weak self] folder in
            self?.sendNotificatoin(title: NSLocalizedString("No playable music in the filler folder", comment: ""))
            mutefyLog("filler: giving up, nothing playable in '\(folder)'")
        }

        spotifyManager.filler.onCountChanged = { [weak self] count in
            self?.settingsModel.playableCount = count
        }

        settingsModel.onFillerChanged = { [weak self] folderChanged in
            guard let filler = self?.spotifyManager?.filler else { return }
            if folderChanged { filler.invalidateFolderCache() }
            filler.refreshVolume()
        }

        // Build the file list now rather than during the first ad. Walking ~/Music on a Mac
        // with an Apple Music library measured 50 seconds — long enough that the filler
        // arrived with 5 seconds of the break left.
        spotifyManager.filler.warmUp()

        settingsModel.onAdvancedChanged = { [weak self] in
            self?.spotifyManager?.applySettings()
        }

        settingsModel.onExclusivityChanged = { [weak self] in
            self?.syncRestartToSkipAdsFromDefaults()
        }

        addSettingsMenuItem()

        // Before anything else touches the volume: a previous run may have died mid-ad and
        // left Spotify silent. Runs even when ad muting is off, because the stale value is
        // ours either way.
        spotifyManager.recoverStaleMuteIfNeeded()

        // The safety ceiling only advances when something asks, so a fallback poll is not
        // optional — file events alone cannot rescue a stuck mute.
        spotifyManager.startPolling()
    }

    /// Inserts the settings item programmatically rather than in MainMenu.xib, so the six
    /// existing localisations do not each need editing to gain one row.
    private func addSettingsMenuItem() {
        let item = NSMenuItem(
            title: NSLocalizedString("Settings…", comment: ""),
            action: #selector(openSettings(_:)),
            keyEquivalent: ",")
        item.target = self
        // Just under the title row, where a settings entry is expected.
        statusMenu.insertItem(item, at: min(1, statusMenu.numberOfItems))
        statusMenu.insertItem(.separator(), at: min(2, statusMenu.numberOfItems))
    }

    @objc func openSettings(_ sender: Any) {
        SettingsWindowController.show(model: settingsModel)
    }

    /// Keeps the status menu tick in step when the settings window flips the exclusivity.
    private func syncRestartToSkipAdsFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: restartToSkipAdsKey)
        spotifyManager?.restartToSkipAdsEnabled = enabled
        restartToSkipAdsCheckbox.state = enabled ? .on : .off
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave Spotify silenced because we went away. This is the failure the Windows
        // build actually hit, and here it would persist across launches.
        spotifyManager?.filler.stopImmediately()
        spotifyManager?.restoreVolumeBeforeQuitting()
        mutefyLog("=== Mutefy stopping ===")
    }
    
    func setStatusBarTitle(title: StatusBarTitle) {
        statusItem.button?.title = title.rawValue
        
        if notificationsEnabled && title == StatusBarTitle.ad {
            sendNotificatoin(title: "Muting Spotify advertisement")
        }
    }
    
    func sendNotificatoin(title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "You can disable notifications in the status bar"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request)
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func configureNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in
        }
    }
    
    func openWebsite(url: String) {
        let url = URL(string: url)
        NSWorkspace.shared.open(url!)
    }
    
}

