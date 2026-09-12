// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import OSLog

struct DownloadedView: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        Group {
            if let serverId = container?.serverState.activeServer?.id {
                DownloadedContent(serverId: serverId)
            } else {
                EmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "尚未连接音乐库",
                    subtitle: "连接服务器后，下载的歌曲会保存在这里。"
                )
            }
        }
        .cassetteContentWidth()
        .navigationTitle("本地歌曲")
    }
}

// MARK: - Song-only offline content

private struct DownloadedContent: View {
    let serverId: UUID
    @Environment(\.appContainer) private var container

    // Album / playlist records are retained only as internal download bookkeeping so older
    // downloads can still be cleaned up correctly. They are deliberately NOT projected into
    // the offline UI: the user-facing offline library is song-only.
    @Query private var albums: [DownloadedAlbum]
    @Query private var playlists: [DownloadedPlaylist]
    @Query private var tracks: [DownloadedTrack]

    @State private var searchText = ""
    @State private var showDeleteAllConfirmation = false
    @State private var isDeletingAll = false

    init(serverId: UUID) {
        self.serverId = serverId
        let sid = serverId
        _albums = Query(
            filter: #Predicate<DownloadedAlbum> { album in album.serverId == sid },
            sort: [SortDescriptor(\DownloadedAlbum.name)]
        )
        _playlists = Query(
            filter: #Predicate<DownloadedPlaylist> { playlist in playlist.serverId == sid },
            sort: [SortDescriptor(\DownloadedPlaylist.name)]
        )
        _tracks = Query(
            filter: #Predicate<DownloadedTrack> { track in track.serverId == sid },
            sort: [SortDescriptor(\DownloadedTrack.downloadedAt, order: .reverse)]
        )
    }

    private var localSongs: [DisplayableSong] {
        tracks.map(DisplayableSong.init(from:))
    }

    private var usedStorage: String {
        ByteCountFormatter.string(
            fromByteCount: tracks.map(\.fileSize).reduce(0, +),
            countStyle: .file
        )
    }

    private var filteredTracks: [DownloadedTrack] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.artist?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    private var filteredSongs: [DisplayableSong] {
        filteredTracks.map(DisplayableSong.init(from:))
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                EmptyStateView(
                    systemImage: "music.note",
                    title: "还没有本地歌曲",
                    subtitle: "在歌曲列表中点击下载，歌曲会直接出现在这里。"
                )
            } else {
                #if os(macOS)
                downloadedListMacOS
                #else
                downloadedListiOS
                #endif
            }
        }
        .confirmationDialog(
            "删除全部本地歌曲？",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除全部", role: .destructive) {
                removeAllDownloads()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前音乐库已下载的全部 \(tracks.count) 首歌曲。此操作不会删除服务器上的音乐。")
        }
    }

    #if os(macOS)
    private var downloadedListMacOS: some View {
        List {
            Section("本地歌曲 · \(filteredTracks.count)") {
                ForEach(Array(filteredSongs.enumerated()), id: \.element.id) { index, song in
                    SongRow(
                        song: song,
                        index: index + 1,
                        showCoverArt: true,
                        onRemoveDownload: { removeDownload(song) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { play(filteredSongs, at: index) }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "搜索本地歌曲、歌手")
    }
    #endif

    private var downloadedListiOS: some View {
        List {
            offlineHero
                .listRowInsets(
                    EdgeInsets(
                        top: CassetteSpacing.s,
                        leading: CassetteSpacing.l,
                        bottom: CassetteSpacing.xxl,
                        trailing: CassetteSpacing.l
                    )
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if !searchText.isEmpty && filteredTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !filteredTracks.isEmpty {
                Section("本地歌曲 · \(filteredTracks.count)") {
                    ForEach(Array(filteredSongs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                            song: song,
                            index: index + 1,
                            showCoverArt: true,
                            onRemoveDownload: { removeDownload(song) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { play(filteredSongs, at: index) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                removeDownload(song)
                            } label: {
                                Label("删除下载", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "搜索本地歌曲、歌手")
        .miniPlayerBottomMargin()
    }

    private var offlineHero: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.l) {
            HStack(alignment: .top, spacing: CassetteSpacing.m) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                    Text("本地歌曲")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Label("\(tracks.count) 首歌曲，可离线播放", systemImage: "checkmark.circle.fill")
                        .font(.cassetteCaption)
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer(minLength: 0)

                Text(usedStorage)
                    .font(.cassetteCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, CassetteSpacing.s)
                    .padding(.vertical, CassetteSpacing.xs)
                    .background(.white.opacity(0.14), in: Capsule())
            }

            HStack(spacing: CassetteSpacing.s) {
                Button {
                    play(localSongs, at: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(CassetteColors.Violet.v700)
                .disabled(localSongs.isEmpty || isDeletingAll)

                Button {
                    play(localSongs.shuffled(), at: 0)
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(localSongs.isEmpty || isDeletingAll)
            }

            Button(role: .destructive) {
                showDeleteAllConfirmation = true
            } label: {
                Label(isDeletingAll ? "正在删除…" : "删除全部本地歌曲", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(isDeletingAll || tracks.isEmpty)
            .accessibilityLabel("删除全部本地歌曲")
        }
        .padding(CassetteSpacing.l)
        .background(
            LinearGradient(
                colors: [CassetteColors.Violet.v500, CassetteColors.Violet.v800],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: CassetteCornerRadius.hero, style: .continuous)
        )
        .shadow(color: CassetteColors.Violet.v700.opacity(0.22), radius: 16, y: 8)
    }

    private func play(_ songs: [DisplayableSong], at index: Int) {
        guard !songs.isEmpty, songs.indices.contains(index) else { return }
        Task {
            do {
                try await container?.playerService.play(tracks: songs, startIndex: index)
            } catch {
                Logger.player.error("[OFFLINE] play failed: \(error, privacy: .public)")
                container?.toastService.showError("无法播放本地音乐")
            }
        }
    }

    private func removeDownload(_ song: DisplayableSong) {
        Task {
            if container?.playerState.currentTrack?.id == song.id {
                try? await container?.playerService.skipToNext()
            }
            do {
                try await container?.downloadService.remove(songId: song.id, serverId: serverId)
                container?.toastService.showSuccess("已删除“\(song.title)”")
            } catch {
                Logger.library.error("[OFFLINE] remove failed: \(error, privacy: .public)")
                container?.toastService.showError("删除下载失败")
            }
        }
    }

    private func removeAllDownloads() {
        guard !isDeletingAll, let container else { return }

        // Snapshot all IDs before SwiftData starts publishing deletions. Album / playlist IDs are
        // housekeeping only: clearing them prevents stale metadata created by older builds from
        // surviving after the song-only library has been emptied.
        let songIds = Array(Set(tracks.map(\.songId)))
        let albumIds = Array(Set(albums.map(\.albumId)))
        let playlistIds = Array(Set(playlists.map(\.playlistId)))
        let downloadedSongIds = Set(songIds)

        isDeletingAll = true
        Task {
            defer { isDeletingAll = false }

            // Do not keep the audio engine attached to a file that is about to disappear.
            if let currentId = container.playerState.currentTrack?.id,
               downloadedSongIds.contains(currentId) {
                await container.playerService.stop()
            }

            var failureCount = 0

            for songId in songIds {
                do {
                    try await container.downloadService.remove(songId: songId, serverId: serverId)
                } catch {
                    failureCount += 1
                    Logger.library.error("[OFFLINE] remove-all song \(songId, privacy: .public) failed: \(error, privacy: .public)")
                }
            }

            // Remove legacy collection bookkeeping after every physical song is gone. This does
            // not re-introduce album/playlist UI; it only avoids orphaned SwiftData records.
            for albumId in albumIds {
                do {
                    try await container.downloadService.remove(albumId: albumId, serverId: serverId)
                } catch {
                    failureCount += 1
                    Logger.library.error("[OFFLINE] remove-all album metadata \(albumId, privacy: .public) failed: \(error, privacy: .public)")
                }
            }

            for playlistId in playlistIds {
                do {
                    try await container.downloadService.remove(playlistId: playlistId, serverId: serverId)
                } catch {
                    failureCount += 1
                    Logger.library.error("[OFFLINE] remove-all playlist metadata \(playlistId, privacy: .public) failed: \(error, privacy: .public)")
                }
            }

            searchText = ""
            if failureCount == 0 {
                container.toastService.showSuccess("已删除全部本地歌曲")
            } else {
                container.toastService.showError("部分本地歌曲删除失败（\(failureCount) 项），可再次重试")
            }
        }
    }
}
