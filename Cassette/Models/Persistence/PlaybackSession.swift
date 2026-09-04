// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

/// Persisted playback session — singleton (id = "current").
///
/// Stores the full queue as JSON so the MiniPlayer can restore instantly
/// without a network round-trip. Track metadata is duplicated as top-level
/// fields for fast MiniPlayer rendering before the full queue is decoded.
@Model
final class PlaybackSession {
    @Attribute(.unique) var id: String
    var currentIndex: Int
    var currentPosition: TimeInterval
    var queueData: Data

    // Current track metadata — duplicated for fast MiniPlayer display
    var currentTrackId: String?
    var currentTrackTitle: String?
    var currentTrackArtist: String?
    var currentTrackCoverArtId: String?
    var currentTrackDuration: TimeInterval
    var currentTrackIsDownloaded: Bool

    var lastUpdated: Date
    var repeatModeRaw: String = RepeatMode.off.rawValue
    /// Persisted unified three-state mode (List / Single / Shuffle). Optional for back-compat with
    /// sessions saved before this field existed; `decodedPlaybackMode()` falls back to `repeatModeRaw`.
    var playbackModeRaw: String?

    init(
        currentIndex: Int = 0,
        currentPosition: TimeInterval = 0,
        queue: [DisplayableSong] = [],
        currentTrack: DisplayableSong? = nil,
        repeatMode: RepeatMode = .off,
        playbackMode: PlaybackMode = .list
    ) {
        self.id = "current"
        self.currentIndex = currentIndex
        self.currentPosition = currentPosition
        self.queueData = (try? JSONEncoder().encode(queue)) ?? Data()
        self.currentTrackId = currentTrack?.id
        self.currentTrackTitle = currentTrack?.title
        self.currentTrackArtist = currentTrack?.artist
        self.currentTrackCoverArtId = currentTrack?.coverArtId
        self.currentTrackDuration = currentTrack?.duration ?? 0
        self.currentTrackIsDownloaded = currentTrack?.isDownloaded ?? false
        self.lastUpdated = Date()
        self.repeatModeRaw = repeatMode.rawValue
        self.playbackModeRaw = playbackMode.rawValue
    }

    func decodedQueue() -> [DisplayableSong] {
        (try? JSONDecoder().decode([DisplayableSong].self, from: queueData)) ?? []
    }

    func decodedRepeatMode() -> RepeatMode {
        RepeatMode(rawValue: repeatModeRaw) ?? .off
    }

    /// Resolves the unified three-state mode. Falls back to deriving from `repeatModeRaw` for sessions
    /// saved before `playbackModeRaw` existed (a stored `.one` → Single; otherwise List — older sessions
    /// did not persist shuffle, matching the previous restore behavior).
    func decodedPlaybackMode() -> PlaybackMode {
        if let raw = playbackModeRaw, let mode = PlaybackMode(rawValue: raw) {
            return mode
        }
        return decodedRepeatMode() == .one ? .single : .list
    }

    func update(
        currentIndex: Int,
        currentPosition: TimeInterval,
        queue: [DisplayableSong],
        currentTrack: DisplayableSong?,
        repeatMode: RepeatMode,
        playbackMode: PlaybackMode
    ) {
        self.currentIndex = currentIndex
        self.currentPosition = currentPosition
        self.queueData = (try? JSONEncoder().encode(queue)) ?? Data()
        self.currentTrackId = currentTrack?.id
        self.currentTrackTitle = currentTrack?.title
        self.currentTrackArtist = currentTrack?.artist
        self.currentTrackCoverArtId = currentTrack?.coverArtId
        self.currentTrackDuration = currentTrack?.duration ?? 0
        self.currentTrackIsDownloaded = currentTrack?.isDownloaded ?? false
        self.lastUpdated = Date()
        self.repeatModeRaw = repeatMode.rawValue
        self.playbackModeRaw = playbackMode.rawValue
    }
}
