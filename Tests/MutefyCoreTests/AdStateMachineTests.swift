//
//  AdStateMachineTests.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//
//  Ported from the Windows build's tests/Mutefy.Tests/AdStateMachineTests.cs (also GPL-3.0).
//  Every case here describes a failure that was seen or reasoned about on a real ad break,
//  not a hypothetical.
//

import XCTest
@testable import MutefyCore

final class AdStateMachineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_767_225_600)

    private func machine(debounceMs: Int = 150, maxMuteSeconds: Int = 90) -> AdStateMachine {
        AdStateMachine(enterDebounce: Double(debounceMs) / 1000.0,
                       maxAdDuration: Double(maxMuteSeconds))
    }

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func ms(_ milliseconds: Double) -> Date {
        t0.addingTimeInterval(milliseconds / 1000.0)
    }

    func testMusicIsAdoptedImmediately() {
        let m = machine()
        XCTAssertFalse(m.advance(.notAd, now: t0), "starting state is already 'not an ad'")
        XCTAssertFalse(m.isAd)
    }

    func testAdIsHeldBackUntilTheDebounceElapses() {
        let m = machine(debounceMs: 150)
        m.advance(.notAd, now: t0)

        // A blank-metadata blip between tracks looks exactly like an ad; it must not mute.
        XCTAssertFalse(m.advance(.ad, now: ms(50)))
        XCTAssertFalse(m.isAd)

        XCTAssertTrue(m.advance(.ad, now: ms(200)))
        XCTAssertTrue(m.isAd)
    }

    func testABlipShorterThanTheDebounceNeverBecomesAnAd() {
        let m = machine(debounceMs: 150)
        m.advance(.notAd, now: t0)

        m.advance(.ad, now: ms(40))
        m.advance(.notAd, now: ms(90))
        m.advance(.notAd, now: ms(400))

        XCTAssertFalse(m.isAd)
    }

    func testLeavingAnAdIsNotDebounced() {
        let m = machine(debounceMs: 150)
        m.advance(.notAd, now: t0)
        m.advance(.ad, now: ms(200))
        m.advance(.ad, now: ms(400))
        XCTAssertTrue(m.isAd)

        // Unmuting late is worse than muting late, so exit is immediate.
        XCTAssertTrue(m.advance(.notAd, now: ms(410)))
        XCTAssertFalse(m.isAd)
    }

    func testUnknownReadingsHoldTheLastKnownState() {
        let m = machine(debounceMs: 0)
        m.advance(.ad, now: t0)
        XCTAssertTrue(m.isAd)

        // Spotify not answering is not evidence the ad ended. Treating it as "not an ad"
        // would unmute mid-break every time a query hiccupped.
        XCTAssertFalse(m.advance(.unknown, now: at(1)))
        XCTAssertTrue(m.isAd)
    }

    func testTheSafetyCeilingForcesAWayOutOfAStuckAd() {
        let m = machine(debounceMs: 0, maxMuteSeconds: 90)
        m.advance(.ad, now: t0)
        XCTAssertTrue(m.isAd)

        // Detection has died: every subsequent reading still says "ad".
        XCTAssertFalse(m.advance(.ad, now: at(60)))
        XCTAssertTrue(m.advance(.ad, now: at(91)))

        XCTAssertFalse(m.isAd)
        XCTAssertEqual(m.safetyTrips, 1)
    }

    func testAfterASafetyTripTheAdStateStaysSuppressedUntilSomethingElseIsSeen() {
        let m = machine(debounceMs: 0, maxMuteSeconds: 90)
        m.advance(.ad, now: t0)
        m.advance(.ad, now: at(91))

        // Still claiming an ad — must not re-mute, or we would just loop.
        m.advance(.ad, now: at(92))
        m.advance(.ad, now: at(200))
        XCTAssertFalse(m.isAd)
        XCTAssertEqual(m.safetyTrips, 1)

        // A non-ad reading clears the suppression...
        m.advance(.notAd, now: at(210))
        XCTAssertFalse(m.isAd)

        // ...and the next genuine ad mutes normally again.
        XCTAssertTrue(m.advance(.ad, now: at(220)))
        XCTAssertTrue(m.isAd)
    }

    func testAnInterruptedAdStartsAFreshCeilingWindow() {
        let m = machine(debounceMs: 0, maxMuteSeconds: 90)
        m.advance(.ad, now: t0)
        m.advance(.notAd, now: at(10))

        // Resuming starts a fresh ad window rather than inheriting the old one.
        m.advance(.ad, now: at(20))
        XCTAssertFalse(m.advance(.ad, now: at(100)))
        XCTAssertTrue(m.isAd)
        XCTAssertEqual(m.safetyTrips, 0)
    }

    /// The real break measured on this Mac: two ads back to back, 56 seconds total, with no
    /// gap between them and `player state` never leaving "playing". A 90-second ceiling has
    /// to sit through all of it without tripping.
    func testAMeasuredFiftySixSecondBreakDoesNotTripTheCeiling() {
        let m = machine(debounceMs: 150, maxMuteSeconds: 90)

        m.advance(.notAd, now: t0)
        m.advance(.ad, now: at(0.0))
        m.advance(.ad, now: at(0.5))
        XCTAssertTrue(m.isAd, "debounce should have settled by 500ms")

        // Poll every 500ms for the whole break, as the app does.
        var elapsed = 1.0
        while elapsed < 56.0 {
            XCTAssertFalse(m.advance(.ad, now: at(elapsed)), "no transition mid-break")
            elapsed += 0.5
        }
        XCTAssertTrue(m.isAd)
        XCTAssertEqual(m.safetyTrips, 0, "56s break must not reach a 90s ceiling")

        XCTAssertTrue(m.advance(.notAd, now: at(56.5)))
        XCTAssertFalse(m.isAd)
    }

    /// The same break with the ceiling deliberately lowered, which is how the safety net is
    /// exercised on a real machine — you cannot make detection fail on demand, but you can
    /// make the ceiling arrive early. It must trip once, restore, and then stay out of the
    /// way for the rest of the break rather than re-muting every poll.
    func testALoweredCeilingTripsOnceAndStaysSuppressedForTheRestOfTheBreak() {
        let m = machine(debounceMs: 150, maxMuteSeconds: 10)

        m.advance(.notAd, now: t0)
        m.advance(.ad, now: at(0.0))
        m.advance(.ad, now: at(0.5))
        XCTAssertTrue(m.isAd)

        var transitions = 0
        var elapsed = 1.0
        while elapsed < 58.0 {
            if m.advance(.ad, now: at(elapsed)) { transitions += 1 }
            elapsed += 0.5
        }

        XCTAssertFalse(m.isAd, "must not be muted at the end of the break")
        XCTAssertEqual(m.safetyTrips, 1, "exactly one trip, not one per poll")
        XCTAssertEqual(transitions, 1, "the ceiling should produce a single unmute")

        // Music returning clears the suppression...
        m.advance(.notAd, now: at(58.5))
        // ...and the next break mutes normally again.
        m.advance(.ad, now: at(120.0))
        XCTAssertTrue(m.advance(.ad, now: at(120.5)))
        XCTAssertTrue(m.isAd)
        XCTAssertEqual(m.safetyTrips, 1)
    }

    func testResetClearsSuppressionAndVerdict() {
        let m = machine(debounceMs: 0, maxMuteSeconds: 90)
        m.advance(.ad, now: t0)
        m.advance(.ad, now: at(91))
        XCTAssertEqual(m.safetyTrips, 1)

        m.reset()
        XCTAssertFalse(m.isAd)

        // Suppression is gone, so an ad takes effect straight away again.
        XCTAssertTrue(m.advance(.ad, now: at(100)))
        XCTAssertTrue(m.isAd)
    }
}
