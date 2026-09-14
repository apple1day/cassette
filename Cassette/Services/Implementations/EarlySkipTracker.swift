// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// Pure policy for deciding whether a track transition counts as an early skip.
///
/// "Skip" deliberately means that a track which actually entered playback was replaced by
/// another track before 15 seconds of accumulated, non-paused listening time. Natural endings
/// are excluded so genuinely short songs never inflate the skip count.
nonisolated enum EarlySkipPolicy {
    static let threshold: TimeInterval = 15

    static func shouldCount(
        playedSeconds: TimeInterval,
        everPlayed: Bool,
        reachedNaturalEnd: Bool,
        changedToAnotherTrack: Bool
    ) -> Bool {
        changedToAnotherTrack
            && everPlayed
            && playedSeconds >= 0
            && playedSeconds < threshold
            && !reachedNaturalEnd
    }
}

/// Lightweight persistent counters keyed by server + song ID.
///
/// This intentionally lives outside `PlaybackEvent`: that model only stores qualified listening
/// events (currently >=30 s) and powers Wrapped. Persisting <15 s skips there would make Wrapped
/// treat abandoned starts as real plays. UserDefaults is sufficient here because the local-song
/// screen only needs a durable integer counter per song.
enum EarlySkipStore {
    static let revisionKey = "cassette.earlySkipCounts.revision.v1"
    private static let storagePrefix = "cassette.earlySkipCounts.v1."
    private static let lock = NSLock()

    static func counts(serverId: UUID) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return readCountsLocked(serverId: serverId)
    }

    @discardableResult
    static func increment(serverId: UUID, songId: String) -> Int {
        lock.lock()
        var values = readCountsLocked(serverId: serverId)
        let next = values[songId, default: 0] + 1
        values[songId] = next
        UserDefaults.standard.set(values, forKey: storageKey(serverId: serverId))
        let revision = UserDefaults.standard.integer(forKey: revisionKey) + 1
        UserDefaults.standard.set(revision, forKey: revisionKey)
        lock.unlock()
        return next
    }

    private static func readCountsLocked(serverId: UUID) -> [String: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: storageKey(serverId: serverId)) ?? [:]
        var result: [String: Int] = [:]
        result.reserveCapacity(raw.count)
        for (songId, value) in raw {
            if let number = value as? NSNumber {
                result[songId] = number.intValue
            } else if let intValue = value as? Int {
                result[songId] = intValue
            }
        }
        return result
    }

    private static func storageKey(serverId: UUID) -> String {
        storagePrefix + serverId.uuidString
    }
}

/// App-lifetime observer that measures actual foreground playback segments without changing the
/// audio engine. It watches the single `PlayerState` source of truth and records a skip only when
/// the current track changes to a different track before 15 seconds.
@MainActor
final class EarlySkipTracker {
    static let shared = EarlySkipTracker()

    private var task: Task<Void, Never>?

    private init() {}

    func start(playerState: PlayerState, serverState: ServerState) {
        guard task == nil else { return }

        task = Task { @MainActor [weak playerState, weak serverState] in
            guard let playerState, let serverState else { return }

            var trackedSongId: String?
            var trackedServerId: UUID?
            var playedSeconds: TimeInterval = 0
            var everPlayed = false
            var previousPlaybackState: PlaybackState = .idle
            var previousPosition: TimeInterval = 0
            var previousDuration: TimeInterval = 0
            var lastSampleAt = Date()

            while !Task.isCancelled {
                let now = Date()
                let currentSongId = playerState.currentTrack?.id
                let currentServerId = serverState.activeServer?.id
                let currentPlaybackState = playerState.playbackState
                let sameIdentity = currentSongId == trackedSongId && currentServerId == trackedServerId

                // Count only time spent in the playing state. Cap one sample contribution so an
                // app suspension/background resume cannot be mistaken for minutes of playback.
                let delta = min(max(now.timeIntervalSince(lastSampleAt), 0), 0.5)
                if sameIdentity {
                    if previousPlaybackState == .playing {
                        playedSeconds += delta
                    }
                    if currentPlaybackState == .playing, currentSongId != nil {
                        everPlayed = true
                    }
                } else {
                    if let previousSongId = trackedSongId,
                       let previousServerId = trackedServerId {
                        let tolerance = min(1.5, max(0.5, previousDuration * 0.02))
                        let reachedNaturalEnd = previousDuration > 0
                            && previousPosition >= max(0, previousDuration - tolerance)
                        let changedToAnotherTrack = currentSongId != nil && currentSongId != previousSongId

                        if EarlySkipPolicy.shouldCount(
                            playedSeconds: playedSeconds,
                            everPlayed: everPlayed,
                            reachedNaturalEnd: reachedNaturalEnd,
                            changedToAnotherTrack: changedToAnotherTrack
                        ) {
                            let count = EarlySkipStore.increment(
                                serverId: previousServerId,
                                songId: previousSongId
                            )
                            Logger.player.info(
                                "[EARLY-SKIP] trackId=\(previousSongId, privacy: .public) played=\(playedSeconds, format: .fixed(precision: 1), privacy: .public)s count=\(count, privacy: .public)"
                            )
                        }
                    }

                    trackedSongId = currentSongId
                    trackedServerId = currentServerId
                    playedSeconds = 0
                    everPlayed = currentPlaybackState == .playing && currentSongId != nil
                }

                previousPlaybackState = currentPlaybackState
                previousPosition = playerState.position
                previousDuration = playerState.duration
                lastSampleAt = now

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
