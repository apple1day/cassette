// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Cassette

struct PlayerPresentationMathTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 0])
    func invalidDurationsAreZero(_ value: Double) {
        #expect(PlayerPresentationMath.duration(value) == 0)
    }

    @Test func validDurationIsPreserved() {
        #expect(PlayerPresentationMath.duration(230.5) == 230.5)
    }

    @Test func seekingIsClamped() {
        #expect(PlayerPresentationMath.position(-10, duration: 120) == 0)
        #expect(PlayerPresentationMath.position(150, duration: 120) == 120)
        #expect(PlayerPresentationMath.position(60.5, duration: 120) == 60.5)
        #expect(PlayerPresentationMath.position(.nan, duration: 120) == 0)
        #expect(PlayerPresentationMath.position(.infinity, duration: 120) == 0)
        #expect(PlayerPresentationMath.position(20, duration: .nan) == 0)
        #expect(PlayerPresentationMath.position(20, duration: -1) == 0)
    }

    @Test func timeLabelsHandleMetadataAndLongTracks() {
        #expect(PlayerPresentationMath.timeLabel(0) == "0:00")
        #expect(PlayerPresentationMath.timeLabel(65.9) == "1:05")
        #expect(PlayerPresentationMath.timeLabel(3_661) == "1:01:01")
        #expect(PlayerPresentationMath.timeLabel(.nan) == "0:00")
        #expect(PlayerPresentationMath.timeLabel(.infinity) == "0:00")
        #expect(PlayerPresentationMath.timeLabel(-10) == "0:00")
        #expect(PlayerPresentationMath.timeLabel(.greatestFiniteMagnitude) == "99:59:59")
    }

    @Test func recordTurnsOnceEveryTwentySeconds() {
        var clock = VinylRotationClock()
        clock.setRunning(true, at: 100)
        #expect(clock.angle(at: 105) == 90)
        #expect(clock.angle(at: 110) == 180)
        #expect(clock.angle(at: 120) == 0)
        #expect(clock.angle(at: 125) == 90)
    }

    @Test func pauseResumeDoesNotJumpOrCountSuspendedTime() {
        var clock = VinylRotationClock()
        clock.setRunning(true, at: 100)
        clock.setRunning(false, at: 105)
        #expect(clock.angle(at: 1_000) == 90)
        clock.setRunning(true, at: 1_000)
        #expect(clock.angle(at: 1_000) == 90)
        #expect(clock.angle(at: 1_005) == 180)
        clock.setRunning(false, at: 1_005)
        #expect(clock.angle(at: 2_000) == 180)
    }

    @Test func repeatedStartAndStopAreIdempotent() {
        var clock = VinylRotationClock()
        clock.setRunning(true, at: 100)
        clock.setRunning(true, at: 103)
        #expect(clock.angle(at: 105) == 90)
        clock.setRunning(false, at: 105)
        clock.setRunning(false, at: 108)
        #expect(clock.angle(at: 120) == 90)
    }

    @Test func invalidAndReversedTimestampsCannotPoisonRotation() {
        var clock = VinylRotationClock()
        clock.setRunning(true, at: .nan)
        clock.setRunning(true, at: -1)
        #expect(clock.startedAt == nil)
        clock.setRunning(true, at: 100)
        #expect(clock.angle(at: 90) == 0)
        #expect(clock.angle(at: .infinity).isFinite)
        #expect(clock.angle(at: .greatestFiniteMagnitude).isFinite)
        clock.setRunning(false, at: .infinity)
        #expect(clock.startedAt == 100)
        clock.setRunning(false, at: 105)
        #expect(clock.restingAngle == 90)
    }
}
