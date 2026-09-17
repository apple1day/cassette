// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

nonisolated struct DownloadedSongDTO: Identifiable, Sendable {
    let id: UUID
    let songId: String
    let serverId: UUID
    let title: String
    let artist: String?
    let coverArtId: String?
    let fileSize: Int64
    let downloadedAt: Date
}

@Observable
@MainActor
final class DownloadsViewModel {
    var downloadedSongs: [DownloadedSongDTO] = []
    var usedBytesFormatted: String = "—"
    var isClearingAll = false

    private let modelContainer: ModelContainer
    private let downloadService: any DownloadServiceProtocol
    private let serverState: ServerState

    init(
        modelContainer: ModelContainer,
        downloadService: any DownloadServiceProtocol,
        serverState: ServerState
    ) {
        self.modelContainer = modelContainer
        self.downloadService = downloadService
        self.serverState = serverState
    }

    func loadData() async {
        let context = ModelContext(modelContainer)
        let allTracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        let activeServerId = serverState.activeServer?.id
        let tracks = allTracks
            .filter { activeServerId == nil || $0.serverId == activeServerId }
            .sorted { $0.downloadedAt > $1.downloadedAt }

        downloadedSongs = tracks.map {
            DownloadedSongDTO(
                id: $0.id,
                songId: $0.songId,
                serverId: $0.serverId,
                title: $0.title,
                artist: $0.artist,
                coverArtId: $0.coverArtId,
                fileSize: $0.fileSize,
                downloadedAt: $0.downloadedAt
            )
        }

        let totalBytes = tracks.map(\.fileSize).reduce(0, +)
        usedBytesFormatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    func removeSong(_ song: DownloadedSongDTO) async {
        try? await downloadService.remove(songId: song.songId, serverId: song.serverId)
        await loadData()
    }

    func clearAll() async {
        guard !isClearingAll else { return }
        isClearingAll = true
        defer { isClearingAll = false }

        let context = ModelContext(modelContainer)
        let activeServerId = serverState.activeServer?.id
        let allTracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        let tracks = allTracks.filter { activeServerId == nil || $0.serverId == activeServerId }

        // Snapshot song rows before deletion. Removing a track updates SwiftData immediately,
        // so iterating a live query while awaiting could skip rows.
        let songs = tracks.map { ($0.songId, $0.serverId) }
        for (songId, serverId) in songs {
            try? await downloadService.remove(songId: songId, serverId: serverId)
        }

        // Old builds persisted collection-level bookkeeping. It is no longer part of the
        // user-facing offline model, but clean it after the song files are gone so upgrades do
        // not retain stale "downloaded album/playlist" state.
        let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? []
        let playlists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>())) ?? []
        for album in albums where activeServerId == nil || album.serverId == activeServerId {
            try? await downloadService.remove(albumId: album.albumId, serverId: album.serverId)
        }
        for playlist in playlists where activeServerId == nil || playlist.serverId == activeServerId {
            try? await downloadService.remove(playlistId: playlist.playlistId, serverId: playlist.serverId)
        }

        await loadData()
    }
}
