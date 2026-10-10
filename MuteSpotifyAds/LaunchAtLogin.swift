//
//  LaunchAtLogin.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//

import Foundation
import ServiceManagement

/// Login-item registration, the macOS counterpart of the Windows build's AutoStart.
///
/// `SMAppService` is macOS 13+. The deployment target is 12.0, so on older systems the
/// feature reports itself unavailable and the settings window hides the control rather than
/// offering a switch that silently does nothing. The deprecated `SMLoginItemSetEnabled`
/// route is deliberately not used: it needs a separate helper bundle, which is a lot of
/// moving parts for a checkbox.
enum LaunchAtLogin {

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Reads the real system state rather than our stored preference, so a login item the
    /// user removed in System Settings is reflected correctly.
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns true when the requested state was reached.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            MutefySettings.launchAtLogin = enabled
            mutefyLog("launch at login: \(enabled ? "enabled" : "disabled")")
            return true
        } catch {
            // Most often this is an unsigned build, or the user has denied it in System
            // Settings. Either way the stored preference must not claim success.
            MutefySettings.launchAtLogin = isEnabled
            mutefyLog("launch at login: failed to \(enabled ? "register" : "unregister") — \(error.localizedDescription)")
            return false
        }
    }
}
