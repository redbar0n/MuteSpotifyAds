// swift-tools-version:5.9
//
//  Package.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//
//  This package exists only to put XCTest around AdStateMachine, which is the one piece of
//  logic that can be checked without a Mac, Spotify and a free account all lined up. It
//  compiles the very same source file the app target does — no copy, so the tests cannot
//  drift away from what ships.
//
//  Run with:  swift test
//
//  The app itself is built from MuteSpotifyAds.xcodeproj; this package deliberately does not
//  try to build the AppKit code.
//

import PackageDescription

let package = Package(
    name: "MutefyCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "MutefyCore",
            path: "MuteSpotifyAds",
            // The app's resources and AppKit sources live in this directory too. They are
            // excluded rather than the source list being trusted alone, because SwiftPM
            // still scans for unhandled resources and refuses to build when it finds any.
            exclude: [
                "AppDelegate.swift",
                "Assets.xcassets",
                "Base.lproj",
                "de.lproj",
                "en.lproj",
                "es.lproj",
                "FillerPlayer.swift",
                "generateIcon.sh",
                "Info.plist",
                "it.lproj",
                "ko.lproj",
                "LaunchAtLogin.swift",
                "MuteSpotifyAds.entitlements",
                "MutefyLog.swift",
                "MutefySettings.swift",
                "SettingsWindowController.swift",
                "SpotifyManager.swift",
                "StatusBarTitle.swift",
                "tr.lproj",
                "zh-Hans.lproj",
            ],
            sources: ["AdStateMachine.swift"]),
        .testTarget(
            name: "MutefyCoreTests",
            dependencies: ["MutefyCore"],
            path: "Tests/MutefyCoreTests"),
    ]
)
