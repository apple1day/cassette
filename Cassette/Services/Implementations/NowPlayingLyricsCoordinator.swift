// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

/// Keeps the now-playing title showing the current lyric line while a song plays.
///
/// CarPlay and most car head units render only `MPMediaItemPropertyTitle`, so showing lyrics
/// there previously meant putting lyrics in the *title* — which this coordinator does. It runs
/// independently of the full-screen lyrics view, so the title reflects the lyric even when the
/// player is closed and playback continues in the background.
///
/// Scope: non-live playback only. It resolves the current *synced* lyric line from
/// `PlayerState.position` on a 0.5 s tick (the same cadence the progress timer uses), and pushes
/// it via ``NowPlayingServiceProtocol/setLyricTitle(_:)``. Lyrics are fetched through
/// ``LyricsService`` (already cached by the lyrics view, so this never re-hits the network for a
/// track the user has opened). When disabled, paused-with-no-lyrics, or on a live stream, the real
/// song title is restored.
@MainActor
final class NowPlayingLyricsCoordinator {
    /// UserDefaults key. Defaults to **on** (`object(forKey:) == nil` means never set → enabled).
    private static let enabledKey = "cassette.player.lyricsInNowPlaying"

    private let playerState: PlayerState
    private let serverState: ServerState
    private let lyricsService: LyricsService
    private let nowPlayingService: any NowPlayingServiceProtocol

    private var timer: Timer?
    /// Song id the coordinator is currently tracking; re-fetches lyrics when it changes.
    private var currentSongId: String?
    /// The active synced lyric set, or `nil` when unavailable / unsynced / still loading.
    private var structured: StructuredLyrics?
    /// Last pushed lyric, so the title only updates when the line actually changes.
    private var lastLine: String?

    init(
        playerState: PlayerState,
        serverState: ServerState,
        lyricsService: LyricsService,
        nowPlayingService: any NowPlayingServiceProtocol
    ) {
        self.playerState = playerState
        self.serverState = serverState
        self.lyricsService = lyricsService
        self.nowPlayingService = nowPlayingService
    }

    /// Whether the feature is enabled. Kept as a static so the coordinator doesn't need to
    /// observe UserDefaults manually; read fresh on each tick so the settings toggle applies live.
    private static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // The timer is created on the main run loop (start() is MainActor), so the closure
            // runs on main. assumeIsolated avoids a repeat MainActor hop per tick (mirrors
            // LyricsViewModel's tracking timer).
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick() {
        guard Self.isEnabled else {
            // Disabled: restore the real title exactly once (not every tick).
            if lastLine != nil {
                lastLine = nil
                pushTitle(nil)
            }
            return
        }

        let trackId = playerState.currentTrack?.id
        if trackId != currentSongId {
            currentSongId = trackId
            structured = nil
            lastLine = nil
            if let trackId, !playerState.isLiveStream {
                fetchLyricsIfNeeded(
                    for: trackId,
                    title: playerState.currentTrack?.title,
                    artist: playerState.currentTrack?.artist
                )
            } else {
                pushTitle(nil)
            }
        }

        // Push the current line only while actually playing; when paused the line is stable and
        // the title can keep showing it (no per-tick work).
        if playerState.playbackState == .playing, !playerState.isLiveStream {
            pushLineIfChanged()
        }
    }

    // MARK: - Lyrics resolution

    private func fetchLyricsIfNeeded(for songId: String, title: String?, artist: String?) {
        guard let serverId = serverState.activeServer?.id else { return }
        // Inherits MainActor (created on the MainActor coordinator), so state updates land on main.
        Task {
            let chosen: StructuredLyrics?
            do {
                let list = try await lyricsService.fetchLyrics(
                    forSongId: songId,
                    serverId: serverId,
                    title: title,
                    artist: artist
                )
                chosen = lyricsService.selectBestLanguage(from: list)
            } catch {
                chosen = nil
            }
            structured = (chosen?.synced == true) ? chosen : nil
            pushLineIfChanged()
        }
    }

    private func pushLineIfChanged() {
        guard let structured, structured.synced else {
            if lastLine != nil {
                lastLine = nil
                pushTitle(nil)
            }
            return
        }

        let adjustedMs = Int(playerState.position * 1000) - structured.offset
        guard let index = lineIndex(for: adjustedMs, in: structured.line) else {
            if lastLine != nil {
                lastLine = nil
                pushTitle(nil)
            }
            return
        }

        // Before the first timed line, show nothing (restore the song title). After that, show the
        // line that is currently active — blank lines are skipped so the title doesn't go empty.
        let value = structured.line[index].value
        guard !value.isEmpty else {
            if lastLine != nil {
                lastLine = nil
                pushTitle(nil)
            }
            return
        }

        guard value != lastLine else { return }
        lastLine = value
        pushTitle(value)
    }

    /// Index of the last line whose start time has passed, or `nil` before the first line.
    /// Binary search (bails to linear on an unsynced line) — identical semantics to
    /// ``LyricsViewModel``, kept local to avoid coupling the coordinator to the view model.
    private func lineIndex(for adjustedMs: Int, in lines: [Line]) -> Int? {
        var low = 0
        var high = lines.count - 1
        var found: Int?

        while low <= high {
            let mid = (low + high) / 2
            guard let start = lines[mid].start else {
                return linearIndex(for: adjustedMs, in: lines)
            }
            if start <= adjustedMs {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return found
    }

    private func linearIndex(for adjustedMs: Int, in lines: [Line]) -> Int? {
        var found: Int?
        for (index, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= adjustedMs {
                found = index
            } else {
                break
            }
        }
        return found
    }

    private func pushTitle(_ lyric: String?) {
        Task { await nowPlayingService.setLyricTitle(lyric) }
    }
}
