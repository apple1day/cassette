// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Testing
@testable import Cassette

@Suite("TrackSkipNavigation — cover carousel")
struct TrackSkipNavigationTests {
    @Test func advancesAndRewindsWithinQueue() {
        #expect(TrackSkipNavigation.targetIndex(
            goNext: true, currentIndex: 1, queueCount: 4, repeatMode: .off
        ) == 2)
        #expect(TrackSkipNavigation.targetIndex(
            goNext: false, currentIndex: 1, queueCount: 4, repeatMode: .off
        ) == 0)
    }

    @Test func doesNotExposeBlankPagesAtQueueEdges() {
        #expect(TrackSkipNavigation.targetIndex(
            goNext: false, currentIndex: 0, queueCount: 3, repeatMode: .off
        ) == nil)
        #expect(TrackSkipNavigation.targetIndex(
            goNext: true, currentIndex: 2, queueCount: 3, repeatMode: .off
        ) == nil)
    }

    @Test func wrapsBothDirectionsForRepeatAll() {
        #expect(TrackSkipNavigation.targetIndex(
            goNext: false, currentIndex: 0, queueCount: 3, repeatMode: .all
        ) == 2)
        #expect(TrackSkipNavigation.targetIndex(
            goNext: true, currentIndex: 2, queueCount: 3, repeatMode: .all
        ) == 0)
    }

    @Test func singleItemQueueNeverPagesToItself() {
        #expect(TrackSkipNavigation.targetIndex(
            goNext: true, currentIndex: 0, queueCount: 1, repeatMode: .all
        ) == nil)
        #expect(TrackSkipNavigation.targetIndex(
            goNext: false, currentIndex: 0, queueCount: 1, repeatMode: .all
        ) == nil)
    }

    @Test func rejectsInvalidQueueState() {
        #expect(TrackSkipNavigation.targetIndex(
            goNext: true, currentIndex: 0, queueCount: 0, repeatMode: .off
        ) == nil)
        #expect(TrackSkipNavigation.targetIndex(
            goNext: true, currentIndex: 4, queueCount: 2, repeatMode: .off
        ) == nil)
    }
}
