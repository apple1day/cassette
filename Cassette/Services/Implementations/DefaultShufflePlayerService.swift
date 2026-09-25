// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Keeps Shuffle as the default mode whenever the user explicitly starts playback.
///
/// The wrapped PlayerService still owns the actual queue, audio engine and mode switching.
/// Only explicit `play(tracks:startIndex:)` calls are given the Shuffle default. Internal skips,
/// resume/pause and queue navigation continue through the base service directly, so a manual
/// switch to List or Repeat One remains in effect for the current playback session.
actor DefaultShufflePlayerService: PlayerServiceProtocol {
    nonisolated let state: PlayerState
    private nonisolated let base: any PlayerServiceProtocol

    init(base: any PlayerServiceProtocol) {
        self.base = base
        self.state = base.state
    }

    func play(tracks: [DisplayableSong], startIndex: Int) async throws {
        try await base.play(tracks: tracks, startIndex: startIndex)
        await base.setPlaybackMode(.shuffle)
    }

    func resume() async { await base.resume() }
    func pause() async { await base.pause() }
    func stop() async { await base.stop() }
    func skipToNext() async throws { try await base.skipToNext() }
    func skipToPrevious() async throws { try await base.skipToPrevious() }
    func seek(to position: TimeInterval) async { await base.seek(to: position) }
    func setRepeatMode(_ mode: RepeatMode) async { await base.setRepeatMode(mode) }
    func toggleShuffle() async { await base.toggleShuffle() }
    func setPlaybackMode(_ mode: PlaybackMode) async { await base.setPlaybackMode(mode) }
    func appendToQueue(_ tracks: [DisplayableSong]) async { await base.appendToQueue(tracks) }
    func playNext(_ song: DisplayableSong) async { await base.playNext(song) }
    func playNext(_ songs: [DisplayableSong]) async { await base.playNext(songs) }
    func addToQueue(_ song: DisplayableSong) async { await base.addToQueue(song) }
    func addToQueue(_ songs: [DisplayableSong]) async { await base.addToQueue(songs) }
    func removeFromQueue(at index: Int) async { await base.removeFromQueue(at: index) }
    func moveInQueue(fromIndex: Int, toIndex: Int) async {
        await base.moveInQueue(fromIndex: fromIndex, toIndex: toIndex)
    }
    func restoreSession() async { await base.restoreSession() }
    func handleNetworkRestored() async { await base.handleNetworkRestored() }
    func playRadio(_ station: InternetRadioStation) async throws { try await base.playRadio(station) }
    func playSmartShuffle() async throws { try await base.playSmartShuffle() }
    func playInstantMix(from seed: InstantMixSeed, startingWith seedTrack: DisplayableSong?) async throws {
        try await base.playInstantMix(from: seed, startingWith: seedTrack)
    }
    func setAutoExtendEnabled(_ enabled: Bool) async { await base.setAutoExtendEnabled(enabled) }
    func setVolume(_ volume: Float) async { await base.setVolume(volume) }
    func togglePlayPause() async { await base.togglePlayPause() }
    func saveCurrentPosition() async { await base.saveCurrentPosition() }
    func replayGainSettingsDidChange() async { await base.replayGainSettingsDidChange() }
    func crossfadeSettingsDidChange() async { await base.crossfadeSettingsDidChange() }
    nonisolated func stopAudioEngineSync() { base.stopAudioEngineSync() }
}
