// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// App-lifetime observer that makes each newly-started song queue default to Shuffle.
///
/// PlayerService intentionally resets `isShuffled` when a genuinely new queue starts. That is a
/// sensible neutral default upstream, but Cassette's local experience prefers Shuffle by default.
/// This observer waits until the first song in the new queue is actually playing, then asks the
/// existing PlayerService to enter `.shuffle`. Waiting for `.playing` avoids racing media
/// resolution and preserves the song the user explicitly tapped as the first song.
///
/// The observer only reacts once per newly-started queue. Manual changes back to List or Repeat One
/// are therefore respected for the rest of the current queue. Queue edits such as add/remove/reorder
/// do not force Shuffle again, and radio / Smart Shuffle sessions are ignored.
@MainActor
final class DefaultShuffleTracker {
    static let shared = DefaultShuffleTracker()

    private var task: Task<Void, Never>?

    private init() {}

    func start(
        playerState: PlayerState,
        playerService: any PlayerServiceProtocol
    ) {
        guard task == nil else { return }

        task = Task { @MainActor [weak playerState] in
            guard let playerState else { return }

            var lastQueueIds = playerState.queue.map(\.id)
            var previousTrackId = playerState.currentTrack?.id
            var pendingQueueIds: [String]?

            while !Task.isCancelled {
                let queueIds = playerState.queue.map(\.id)
                let currentTrackId = playerState.currentTrack?.id
                let playbackState = playerState.playbackState
                let queueChanged = queueIds != lastQueueIds
                let trackChanged = currentTrackId != previousTrackId

                if queueIds.isEmpty {
                    // Clearing the queue ends the session. The same list can later be started again
                    // and should once again receive the default Shuffle mode.
                    pendingQueueIds = nil
                    lastQueueIds = []
                } else if queueChanged {
                    // Normal explicit play() exposes the replacement queue while in `.loading`.
                    // The trackChanged+playing fallback covers very fast local-file starts where the
                    // loading state may complete between two samples.
                    if playbackState == .loading || (playbackState == .playing && trackChanged) {
                        pendingQueueIds = queueIds
                    }
                    lastQueueIds = queueIds
                }

                if let pendingQueueIds,
                   playbackState == .playing,
                   queueIds == pendingQueueIds,
                   currentTrackId != nil {
                    if !playerState.isLiveStream && !playerState.isSmartShuffleActive {
                        if playerState.playbackMode != .shuffle {
                            await playerService.setPlaybackMode(.shuffle)
                            Logger.player.debug("[DEFAULT-SHUFFLE] Enabled Shuffle for newly-started queue")
                        }
                    }
                    selfPendingQueueClear(&pendingQueueIds)
                }

                previousTrackId = currentTrackId
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

/// Small helper keeps the optional mutation explicit and avoids accidentally shadowing the local
/// `pendingQueueIds` binding inside the observer's `if let` block.
@MainActor
private func selfPendingQueueClear(_ value: inout [String]?) {
    value = nil
}
