// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Observation
import OSLog
import SwiftSonic

@Observable
@MainActor
final class SongsListViewModel {
    /// The sorted, display-ready list — populated once loading finishes (or when the sort changes).
    private(set) var displaySongs: [DisplayableSong] = []
    /// Live count while paging, for the progress indicator.
    private(set) var loadedCount = 0
    /// True while pages are still being fetched.
    private(set) var isLoading = false
    private(set) var isDownloadingAll = false
    private(set) var downloadCompletedCount = 0
    private(set) var downloadTotalCount = 0
    /// True if the safety cap was hit (server has more songs than we loaded) — surfaced to the user.
    private(set) var didTruncate = false
    var error: UserFacingError?

    private var rawSongs: [Song] = []
    private var currentSort: SongSort = .title
    private let libraryService: any LibraryServiceProtocol
    private let downloadService: any DownloadServiceProtocol
    private let serverState: ServerState

    /// 1000/page keeps the number of round-trips low while staying responsive. The cap is only a backstop
    /// against a server that ignores `songOffset` (metadata is light, so memory isn't the limit).
    private static let pageSize = 1000
    private static let safetyCap = 200_000

    init(
        libraryService: any LibraryServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        serverState: ServerState
    ) {
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.serverState = serverState
    }

    /// Pages the whole library (server order), updating `loadedCount` as it goes, then sorts off-main.
    func load(sort: SongSort) async {
        currentSort = sort
        rawSongs = []
        displaySongs = []
        loadedCount = 0
        didTruncate = false
        error = nil
        isLoading = true
        defer { isLoading = false }

        var offset = 0
        var seen = Set<String>()
        do {
            while rawSongs.count < Self.safetyCap {
                let page = try await libraryService.allSongs(offset: offset, count: Self.pageSize)
                if page.isEmpty { break }
                // No-progress guard: if a full page adds no new ids, the server is ignoring the offset —
                // stop instead of looping forever.
                let fresh = page.filter { seen.insert($0.id).inserted }
                if fresh.isEmpty { break }
                rawSongs.append(contentsOf: fresh)
                loadedCount = rawSongs.count
                if page.count < Self.pageSize { break } // last (short) page
                offset += Self.pageSize
            }
            if rawSongs.count >= Self.safetyCap { didTruncate = true }
            Logger.library.info("All Songs loaded \(self.rawSongs.count, privacy: .public) songs (truncated=\(self.didTruncate, privacy: .public))")
        } catch {
            Logger.library.error("All Songs load failed: \(error, privacy: .public)")
            self.error = UserFacingError.from(error)
        }
        await recomputeDisplay()
        await refreshDownloadedState()
    }

    /// Re-sorts the already-loaded songs (no network) when the user changes the sort.
    func changeSort(_ sort: SongSort) async {
        guard sort != currentSort else { return }
        currentSort = sort
        await recomputeDisplay()
        await refreshDownloadedState()
    }

    /// Sorts + maps off the main actor so large libraries never hitch the UI.
    private func recomputeDisplay() async {
        let raw = rawSongs
        let sort = currentSort
        displaySongs = await Task.detached(priority: .userInitiated) {
            sort.sorted(raw).map { DisplayableSong(from: $0) }
        }.value
    }

    /// Downloads every missing track in the library using the app's existing offline-download pipeline.
    /// The operation is intentionally sequential: v1 uses a foreground URLSession and bounded work avoids
    /// overwhelming small Subsonic servers or exhausting device storage with hundreds of concurrent files.
    func downloadAll() async -> Int {
        guard !isDownloadingAll, let serverId = serverState.activeServer?.id else { return 0 }
        isDownloadingAll = true
        defer { isDownloadingAll = false }

        let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        let pending = rawSongs.filter { !downloadedIds.contains($0.id) }
        downloadTotalCount = pending.count
        downloadCompletedCount = 0
        var failures = 0

        for song in pending {
            do {
                try await downloadService.download(song: song, serverId: serverId)
            } catch {
                failures += 1
                Logger.download.error("All Songs download failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
            }
            downloadCompletedCount += 1
            if let index = displaySongs.firstIndex(where: { $0.id == song.id }) {
                displaySongs[index] = displaySongs[index].withDownloaded(true)
            }
        }
        await refreshDownloadedState()
        return failures
    }

    func refreshDownloadedState() async {
        guard let serverId = serverState.activeServer?.id else { return }
        let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        displaySongs = displaySongs.map { $0.withDownloaded(downloadedIds.contains($0.id)) }
    }
}
