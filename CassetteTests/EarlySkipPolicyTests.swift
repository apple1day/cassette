// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
@testable import Cassette

@Suite("Early skip policy")
struct EarlySkipPolicyTests {
    @Test("a played track switched before 15 seconds counts")
    func belowThresholdCounts() {
        #expect(EarlySkipPolicy.shouldCount(
            playedSeconds: 14.9,
            everPlayed: true,
            reachedNaturalEnd: false,
            changedToAnotherTrack: true
        ))
    }

    @Test("exactly 15 seconds does not count")
    func thresholdDoesNotCount() {
        #expect(!EarlySkipPolicy.shouldCount(
            playedSeconds: 15,
            everPlayed: true,
            reachedNaturalEnd: false,
            changedToAnotherTrack: true
        ))
    }

    @Test("natural completion of a short song does not count")
    func naturalEndDoesNotCount() {
        #expect(!EarlySkipPolicy.shouldCount(
            playedSeconds: 9,
            everPlayed: true,
            reachedNaturalEnd: true,
            changedToAnotherTrack: true
        ))
    }

    @Test("a track that never entered playing does not count")
    func unresolvedTrackDoesNotCount() {
        #expect(!EarlySkipPolicy.shouldCount(
            playedSeconds: 0,
            everPlayed: false,
            reachedNaturalEnd: false,
            changedToAnotherTrack: true
        ))
    }

    @Test("stopping without selecting another song does not count")
    func stopDoesNotCount() {
        #expect(!EarlySkipPolicy.shouldCount(
            playedSeconds: 5,
            everPlayed: true,
            reachedNaturalEnd: false,
            changedToAnotherTrack: false
        ))
    }
}
