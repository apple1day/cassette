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
                    subtitle: "连接服务器后，下载的音乐会保存在这里。"
                )
            }
        }
        .cassetteContentWidth()
        .navigationTitle("离线音乐")
    }
}

// MARK: - Content

private struct DownloadedContent: View {
    let serverId: UUID
    @Environment(\.appContainer) private var container
    @Query private var albums: [DownloadedAlbum]
    @Query private var playlists: [DownloadedPlaylist]
    @Query private var tracks: [DownloadedTrack]
    @State private var searchText = ""

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

    private var displayAlbums: [DownloadedAlbumDisplay] {
        DownloadedAlbumMerger.merge(records: albums, tracks: tracks)
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

    private var incompleteCollectionsCount: Int {
        let albumCount = displayAlbums.filter { album in
            guard let total = album.totalTracksCount else { return false }
            return album.downloadedTracksCount < total
        }.count
        return albumCount + playlists.filter { !$0.isComplete }.count
    }

    private var filteredAlbums: [DownloadedAlbumDisplay] {
        guard !searchText.isEmpty else { return displayAlbums }
        return displayAlbums.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.artist?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    private var filteredPlaylists: [DownloadedPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredTracks: [DownloadedTrack] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.artist?.localizedCaseInsensitiveContains(searchText) == true)
                || ($0.album?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    private var filteredSongs: [DisplayableSong] {
        filteredTracks.map(DisplayableSong.init(from:))
    }

    var body: some View {
        if displayAlbums.isEmpty && playlists.isEmpty && tracks.isEmpty {
            EmptyStateView(
                systemImage: "arrow.down.circle",
                title: "还没有离线音乐",
                subtitle: "在歌曲、专辑或歌单中点击下载，即使没有网络也能播放。"
            )
        } else {
            #if os(macOS)
            downloadedListMacOS
            #else
            downloadedListiOS
            #endif
        }
    }

    #if os(macOS)
    private var downloadedListMacOS: some View {
        ScrollViewReader { proxy in
            List {
                if !displayAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(displayAlbums) { display in
                            NavigationLink(value: HomeDestination.downloadedAlbum(display)) {
                                HStack(spacing: CassetteSpacing.m) {
                                    CoverArtCard(id: display.coverArtId ?? display.albumId, size: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(display.name)
                                            .font(.cassetteCellTitle)
                                            .lineLimit(1)
                                        if let artist = display.artist {
                                            Text(artist)
                                                .font(.cassetteCellSubtitle)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Text("\(display.downloadedTracksCount) tracks")
                                            .font(.cassetteCaption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, CassetteSpacing.xs)
                            }
                            .id(display.id)
                        }
                    }
                }

                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: HomeDestination.playlistById(id: playlist.playlistId, name: playlist.name, coverArtId: playlist.coverArtId)) {
                                HStack(spacing: CassetteSpacing.m) {
                                    CoverArtCard(id: playlist.coverArtId ?? playlist.playlistId, size: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.cassetteCellTitle)
                                            .lineLimit(1)
                                        Text("\(playlist.tracksCount) tracks\(playlist.isComplete ? "" : " (incomplete)")")
                                            .font(.cassetteCaption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, CassetteSpacing.xs)
                            }
                        }
                    }
                }

                if !tracks.isEmpty {
                    Section("Songs") {
                        ForEach(Array(localSongs.enumerated()), id: \.element.id) { index, song in
                            SongRow(
                                song: song,
                                index: index + 1,
                                showCoverArt: true,
                                onRemoveDownload: { removeDownload(song) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { play(localSongs, at: index) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
    #endif

    private var downloadedListiOS: some View {
        List {
            offlineHero
                .listRowInsets(EdgeInsets(top: CassetteSpacing.s, leading: CassetteSpacing.l, bottom: CassetteSpacing.xxl, trailing: CassetteSpacing.l))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if !searchText.isEmpty && filteredAlbums.isEmpty && filteredPlaylists.isEmpty && filteredTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !filteredAlbums.isEmpty {
                Section("离线专辑 · \(filteredAlbums.count)") {
                    ForEach(filteredAlbums) { display in
                        NavigationLink {
                            AlbumDetailView(
                                albumId: display.albumId,
                                albumName: display.name,
                                coverArtId: display.coverArtId,
                                mode: .downloadedOnly
                            )
                        } label: {
                            downloadedAlbumRow(display)
                        }
                    }
                }
            }

            if !filteredPlaylists.isEmpty {
                Section("离线歌单 · \(filteredPlaylists.count)") {
                    ForEach(filteredPlaylists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(
                                playlistId: playlist.playlistId,
                                name: playlist.name,
                                coverArtId: playlist.coverArtId
                            )
                        } label: {
                            downloadedPlaylistRow(playlist)
                        }
                    }
                }
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
        .searchable(text: $searchText, prompt: "搜索本地歌曲、歌手、专辑")
        .miniPlayerBottomMargin()
    }

    private var offlineHero: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.l) {
            HStack(alignment: .top, spacing: CassetteSpacing.m) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                    Text("随时可播")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Label(
                        container?.serverState.isOnline == true ? "网络可用" : "当前为离线模式",
                        systemImage: container?.serverState.isOnline == true ? "wifi" : "wifi.slash"
                    )
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

            HStack(spacing: 0) {
                offlineStat(value: tracks.count.formatted(), label: "歌曲")
                Divider().overlay(.white.opacity(0.22))
                offlineStat(value: displayAlbums.count.formatted(), label: "专辑")
                Divider().overlay(.white.opacity(0.22))
                offlineStat(value: playlists.count.formatted(), label: "歌单")
            }
            .frame(height: 42)

            if incompleteCollectionsCount > 0 {
                Label("\(incompleteCollectionsCount) 个专辑或歌单尚未完整下载", systemImage: "exclamationmark.circle.fill")
                    .font(.cassetteCaption)
                    .foregroundStyle(.white.opacity(0.84))
            } else {
                Label("本地收藏已完整保存", systemImage: "checkmark.circle.fill")
                    .font(.cassetteCaption)
                    .foregroundStyle(.white.opacity(0.84))
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
                .disabled(localSongs.isEmpty)

                Button {
                    play(localSongs.shuffled(), at: 0)
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(localSongs.isEmpty)
            }
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

    private func offlineStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private func downloadedAlbumRow(_ display: DownloadedAlbumDisplay) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            CoverArtCard(id: display.coverArtId ?? display.albumId, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(display.name)
                    .font(.cassetteCellTitle)
                    .lineLimit(1)
                if let artist = display.artist {
                    Text(artist)
                        .font(.cassetteCellSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                downloadProgressLabel(
                    downloaded: display.downloadedTracksCount,
                    total: display.totalTracksCount
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, CassetteSpacing.xs)
    }

    private func downloadedPlaylistRow(_ playlist: DownloadedPlaylist) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            PlaylistCoverThumbnail(
                playlistId: playlist.playlistId,
                serverId: playlist.serverId,
                coverArtId: playlist.coverArtId ?? playlist.playlistId,
                title: playlist.name,
                size: 56
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.cassetteCellTitle)
                    .lineLimit(1)
                downloadProgressLabel(downloaded: playlist.tracksCount, total: playlist.totalTracksCount)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, CassetteSpacing.xs)
    }

    private func downloadProgressLabel(downloaded: Int, total: Int?) -> some View {
        let isComplete = total == nil || downloaded >= (total ?? downloaded)
        return Label {
            Text(total.map { "\(downloaded)/\($0) 首" } ?? "\(downloaded) 首")
        } icon: {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        }
        .font(.cassetteCaption)
        .foregroundStyle(isComplete ? Color.secondary : Color.orange)
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
}
