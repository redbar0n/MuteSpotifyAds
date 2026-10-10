//
//  AdStateMachine.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//
//  Ported from the Windows build of Mutefy (src/Mutefy.Core/AdStateMachine.cs), which is
//  also GPL-3.0. The two protections below were added there after real ad breaks were
//  measured; neither exists in the macOS app this fork descends from.
//

import Foundation

/// What a single probe reading says. `unknown` is not a failure — it is the honest answer
/// when Spotify is not running or AppleScript returned nothing, and it must be
/// distinguishable from "definitely not an ad" so a hiccup cannot unmute mid-ad.
enum AdReading {
    case notAd
    case ad
    case unknown
}

/// Turns a stream of noisy readings into a stable verdict.
///
/// **Entry debounce.** Spotify blanks its metadata for a moment between tracks, which reads
/// exactly like an ad. Requiring the verdict to hold avoids a mute blip on every track
/// change. Exit is *not* debounced — leaving music muted is the worse failure, so we unmute
/// the instant the ad verdict drops.
///
/// **Safety ceiling.** If detection dies mid-ad (Spotify changes its metadata format, the
/// AppleScript bridge breaks, the file watcher stops firing) we would otherwise leave
/// Spotify silenced indefinitely with no way back. Past `maxAdDuration` we force our way out
/// and refuse to re-enter the ad state until the detector has said something else at least
/// once. A measured Korean free-account break ran 56 seconds (two ads back to back), so the
/// ceiling has to clear well over a minute.
///
/// Note this only advances when `advance` is called, which is why the caller polls rather
/// than relying on file-change events alone — a detector that has stopped producing events
/// would never reach its own ceiling.
///
/// Deliberately free of AppKit so it can be tested against a synthetic clock.
final class AdStateMachine {

    private let enterDebounce: TimeInterval
    private let maxAdDuration: TimeInterval

    private var adCandidateSince: Date?
    private var adSince: Date = .distantPast
    private var suppressAd = false

    /// Current settled verdict.
    private(set) var isAd = false

    /// How many times the ceiling has forced us out. Non-zero means detection failed and is
    /// worth surfacing rather than silently recovering from.
    private(set) var safetyTrips = 0

    init(enterDebounce: TimeInterval, maxAdDuration: TimeInterval) {
        self.enterDebounce = enterDebounce
        self.maxAdDuration = maxAdDuration
    }

    /// Feeds one reading in. Returns true when `isAd` changed.
    @discardableResult
    func advance(_ reading: AdReading, now: Date = Date()) -> Bool {
        var incoming = reading

        // A previous safety trip stays in force until the detector stops claiming an ad.
        if suppressAd {
            if incoming == .ad {
                incoming = .notAd
            } else {
                suppressAd = false
            }
        }

        // Check the ceiling before anything else, so a stuck detector cannot outvote it.
        if isAd && now.timeIntervalSince(adSince) >= maxAdDuration {
            suppressAd = true
            adCandidateSince = nil
            safetyTrips += 1
            isAd = false
            return true
        }

        // No opinion from the probe: hold whatever we last decided.
        if incoming == .unknown { return false }

        if incoming == .ad {
            if adCandidateSince == nil { adCandidateSince = now }
            if now.timeIntervalSince(adCandidateSince!) < enterDebounce { return false }
        } else {
            adCandidateSince = nil
        }

        let wantsAd = incoming == .ad
        if isAd == wantsAd { return false }

        isAd = wantsAd
        if wantsAd { adSince = now }
        return true
    }

    /// Clears all state, e.g. when the feature is switched off.
    func reset() {
        isAd = false
        adCandidateSince = nil
        suppressAd = false
    }
}
