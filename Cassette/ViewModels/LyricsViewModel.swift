// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

@Observable
@MainActor
final class LyricsViewModel {
    private let lyricsService: LyricsService
    private let playerService: any PlayerServiceProtocol
    private let playerState: PlayerState
    private let songId: String
    private let serverId: UUID
    /// Song metadata, used only by the legacy `getLyrics` fallback — see ``LyricsService``.
    private let title: String?
    private let artist: String?

    private(set) var state: State = .loading
    private(set) var currentLineIndex: Int?
    private(set) var availableLanguages: [String] = []
    var selectedLanguage: String?
    var autoScrollEnabled: Bool = true
    private(set) var isUserScrolling: Bool = false

    private var lyricsList: LyricsList?
    private var trackingTimer: Timer?
    private var resumeTask: Task<Void, Never>?
    private var isShown = false

    nonisolated enum State: Equatable {
        case loading
        case loaded(StructuredLyrics)
        case empty
        case unsupported
        case error(String)
    }

    init(
        songId: String,
        serverId: UUID,
        lyricsService: LyricsService,
        playerService: any PlayerServiceProtocol,
        playerState: PlayerState,
        title: String? = nil,
        artist: String? = nil
    ) {
        self.songId = songId
        self.serverId = serverId
        self.lyricsService = lyricsService
        self.playerService = playerService
        self.playerState = playerState
        self.title = title
        self.artist = artist
    }

    // MARK: - Load

    func load() async {
        state = .loading
        do {
            let list = try await lyricsService.fetchLyrics(
                forSongId: songId,
                serverId: serverId,
                title: title,
                artist: artist
            )
            lyricsList = list
            applyCurrentLanguage()
        } catch LyricsError.notSupportedByServer {
            state = .unsupported
        } catch LyricsError.notFound {
            state = .empty
        } catch let error as LyricsError {
            state = .error(networkErrorMessage(from: error))
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Clears the cached result for this song and loads again.
    ///
    /// Without the invalidation step a retry would keep serving the negative cache —
    /// including the "no lyrics" entry written the last time every source came back
    /// empty — and the user would see no change.
    func retry() async {
        await lyricsService.invalidate(songId: songId, serverId: serverId)
        await load()
    }

    // MARK: - Line tracking

    func update(elapsedMs: Int) {
        guard case .loaded(let structured) = state, structured.synced else {
            currentLineIndex = nil
            return
        }
        let newIndex = lineIndex(
            for: elapsedMs - structured.offset,
            in: structured.line
        )
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }

    /// Index of the last line whose start time has passed, or `nil` before the first line.
    ///
    /// Binary search, because this runs on a 10 Hz timer and a long track can carry
    /// several hundred lines.
    ///
    /// The search assumes ascending start times. Synced sets satisfy that; a line with
    /// no start time does not, and bisecting past one can skip the correct line
    /// entirely — so the search bails out to ``linearIndex(for:in:)`` the moment it
    /// meets one. Behaviour is then identical to the linear walk it replaces.
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

    /// The straightforward walk, kept for line sets that carry an unsynced line.
    private func linearIndex(for adjustedMs: Int, in lines: [Line]) -> Int? {
        var newIndex: Int?
        for (index, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= adjustedMs {
                newIndex = index
            } else {
                break
            }
        }
        return newIndex
    }

    // MARK: - Seek

    func userTapped(lineIndex: Int) {
        guard case .loaded(let structured) = state, structured.synced else { return }
        guard lineIndex < structured.line.count else { return }
        guard let startMs = structured.line[lineIndex].start else { return }
        let targetSeconds = TimeInterval(startMs + structured.offset) / 1000.0
        Task { [weak self] in
            await self?.playerService.seek(to: targetSeconds)
        }
    }

    // MARK: - Auto-scroll

    func userStartedScrolling() {
        isUserScrolling = true
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isUserScrolling = false }
        }
    }

    func userStoppedScrolling() {
        userStartedScrolling()
    }

    // MARK: - Language selection

    func selectLanguage(_ lang: String) {
        guard selectedLanguage != lang else { return }
        selectedLanguage = lang
        currentLineIndex = nil
        applyCurrentLanguage()
    }

    // MARK: - Timer lifecycle

    /// True while playback is playing. Exposed so the lyrics view can reconcile tracking on play/pause.
    var isPlaying: Bool { playerState.playbackState == .playing }

    private var hasSyncedLyrics: Bool {
        if case .loaded(let structured) = state { return structured.synced }
        return false
    }

    /// Called when the lyrics view appears/disappears. The auto-scroll resume task is torn down on hide.
    func setVisible(_ visible: Bool) {
        isShown = visible
        if !visible {
            resumeTask?.cancel()
            resumeTask = nil
        }
        reconcileTracking()
    }

    /// Single source of truth for the 10 Hz line-tracking timer: it runs ONLY while the lyrics are
    /// visible AND playback is playing AND the current lyrics are time-synced. The timer is never started
    /// at init; it is torn down the instant any condition goes false (hide, pause, unsynced) so a paused or
    /// hidden player does no per-tick work. Idempotent — safe to call on any condition change.
    func reconcileTracking() {
        if isShown && isPlaying && hasSyncedLyrics {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update(elapsedMs: Int(self.playerState.position * 1000))
            }
        }
    }

    private func stopTimer() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    // MARK: - Private helpers

    private func applyCurrentLanguage() {
        guard let list = lyricsList else { return }
        var seen = Set<String>()
        availableLanguages = list.structuredLyrics
            .compactMap { $0.lang }
            .filter { seen.insert($0).inserted }
        let best = lyricsService.selectBestLanguage(from: list, preferred: selectedLanguage)
        currentLineIndex = nil
        state = best.map { .loaded($0) } ?? .empty
        // Lyrics (and their synced-ness) just changed — start the timer if it should now run.
        reconcileTracking()
    }

    private func networkErrorMessage(from error: LyricsError) -> String {
        if case .networkError(let msg) = error { return msg }
        return error.localizedDescription
    }
}
