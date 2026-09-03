// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

/// Library-wide "All Songs" list. Pages the whole library (search3's empty-query wildcard) with a live
/// progress count, sorts off-main, and shows a Play/Shuffle-all header, a persisted sort control, and an
/// A–Z jump bar when sorted by title.
struct SongsListView: View {
    @Environment(\.appContainer) private var container
    @Query(sort: \DownloadedTrack.title) private var downloadedTracks: [DownloadedTrack]
    @Query(sort: \DownloadedPlaylist.name) private var downloadedPlaylists: [DownloadedPlaylist]
    @State private var viewModel: SongsListViewModel?
    /// Persisted sort — Title by default, plus Artist / Recently Added / Release Date.
    @AppStorage("cassette.songSort") private var songSort: SongSort = .title

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        #if os(iOS)
        .cassetteContentWidth()
        #endif
        .navigationTitle("歌曲")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SongSortMenu(sort: $songSort)
            }
        }
        .task(id: container?.serverState.isOnline) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil, let c = container {
                viewModel = SongsListViewModel(
                    libraryService: svc,
                    downloadService: c.downloadService,
                    serverState: c.serverState
                )
            }
            guard container?.serverState.isOnline == true else { return }
            await viewModel?.load(sort: songSort)
        }
        .onChange(of: songSort) { _, newSort in
            Task { await viewModel?.changeSort(newSort) }
        }
    }

    @ViewBuilder
    private func content(_ vm: SongsListViewModel) -> some View {
        if vm.displaySongs.isEmpty {
            // KEY FIX: never stall the user on a full-screen spinner when they
            // have already downloaded music on-device. Local data renders first,
            // and a server refresh runs behind it with a small inline banner.
            // The full-screen ProgressView is kept ONLY for the true empty edge
            // case: nothing on disk and a server fetch is the user's only option.
            let serverID = container?.serverState.activeServer?.id
            let songs = downloadedTracks
                .filter { serverID == nil || $0.serverId == serverID }
                .map(DisplayableSong.init(from:))
            let playlists = downloadedPlaylists
                .filter { serverID == nil || $0.serverId == serverID }

            if vm.isLoading && songs.isEmpty && playlists.isEmpty {
                loadingProgress(vm)
            } else {
                offlineSongList(
                    songs: songs,
                    playlists: playlists,
                    showLoadingBanner: vm.isLoading
                )
            }
        } else {
            songList(vm)
        }
    }

    /// The app is primarily useful away from the home computer that hosts the music server.
    /// When it is unreachable, keep the same song-first surface and source it from SwiftData
    /// instead of falling back to the album/folder download browser.
    ///
    /// Shows downloaded playlists above downloaded songs so users can find collections they
    /// saved for offline use without drilling into a separate "歌单" screen first.
    ///
    /// - Parameters:
    ///   - songs: pre-filtered downloaded tracks for the active server.
    ///   - playlists: pre-filtered downloaded playlists for the active server.
    ///   - showLoadingBanner: when true, an inline "正在从服务器刷新…" banner is shown
    ///     above the list (used while a server load is in flight — without replacing the
    ///     already-usable local content with a spinner).
    @ViewBuilder
    private func offlineSongList(
        songs: [DisplayableSong],
        playlists: [DownloadedPlaylist],
        showLoadingBanner: Bool
    ) -> some View {
        if songs.isEmpty && playlists.isEmpty {
            EmptyStateView(
                systemImage: "arrow.down.circle",
                title: "暂无本地音乐",
                subtitle: "连接你的电脑后，在歌曲页或歌单页下载音乐，即可离线播放。"
            )
        } else {
            VStack(spacing: 0) {
                if showLoadingBanner {
                    offlineRefreshBanner
                }
                List {
                    if !playlists.isEmpty {
                        Section("本地歌单") {
                            ForEach(playlists) { playlist in
                                NavigationLink(value: HomeDestination.playlistById(
                                    id: playlist.playlistId,
                                    name: playlist.name,
                                    coverArtId: playlist.coverArtId
                                )) {
                                    offlinePlaylistRow(playlist)
                                }
                            }
                        }
                    }

                    if !songs.isEmpty {
                        Section("本地歌曲") {
                            offlineMusicHeader(songs: songs)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        Section {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                SongRow(
                                    song: song,
                                    index: index + 1,
                                    showCoverArt: true,
                                    isFavorite: isFavorite(song),
                                    onRemoveDownload: { removeOfflineDownload(song) }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { play(songs, at: index) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        removeOfflineDownload(song)
                                    } label: {
                                        Label("删除下载", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .miniPlayerBottomMargin()
            }
        }
    }

    /// Small top-of-list banner shown when the server is being refreshed in the
    /// background while the user already has local downloads. Replaces the
    /// full-screen `LoadingStateView` for the already-usable-offline case.
    private var offlineRefreshBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
            Text("正在从服务器刷新…")
                .font(.cassetteCaption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cassetteAccent.opacity(0.06))
    }

    /// A single row for an offline playlist in the home list — mirrors OfflinePlaylistRow
    /// (from PlaylistListView) but shares the local PlaylistCoverThumbnail renderer so
    /// cover art stays consistent across surfaces.
    private func offlinePlaylistRow(_ playlist: DownloadedPlaylist) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            PlaylistCoverThumbnail(
                playlistId: playlist.playlistId,
                serverId: playlist.serverId,
                coverArtId: playlist.coverArtId ?? playlist.playlistId,
                title: playlist.name,
                size: 56
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.cassetteCellTitle)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(playlist.tracksCount) 首")
                        .font(.cassetteCaption)
                        .foregroundStyle(.secondary)
                    if playlist.tracksCount != playlist.totalTracksCount {
                        Text("(未完整)")
                            .font(.cassetteCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, CassetteSpacing.xs)
    }

    /// Removes a downloaded track from the device. If the track is currently playing,
    /// skip to the next queue item first so deleting the underlying audio file doesn't
    /// strand the player in an error state. `@Query downloadedTracks` auto-refreshes the list.
    private func removeOfflineDownload(_ song: DisplayableSong) {
        Task { @MainActor in
            guard let container, let serverId = container.serverState.activeServer?.id else { return }
            // 删除当前播放歌曲前先跳到下一首,避免 AudioStreaming 进入错误状态
            if container.playerState.currentTrack?.id == song.id {
                try? await container.playerService.skipToNext()
            }
            do {
                try await container.downloadService.remove(songId: song.id, serverId: serverId)
                container.toastService.showSuccess("已删除“\(song.title)”")
            } catch {
                Logger.library.error("Remove download failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
                container.toastService.showError("删除失败:\(error.localizedDescription)")
            }
        }
    }

    private func offlineMusicHeader(songs: [DisplayableSong]) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(Color.cassetteAccent)
                .frame(width: 44, height: 44)
                .background(CassetteColors.accentBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("本地音乐 · 离线播放")
                    .font(.cassetteCellTitle)
                Text("已下载 \(songs.count.formatted()) 首歌曲")
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                Task { try? await container?.playerService.play(tracks: songs, startIndex: 0) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.headline)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cassetteAccent)
            .accessibilityLabel("播放本地歌曲")
        }
        .padding(.vertical, CassetteSpacing.s)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Live count while the library pages in — so a large library shows progress, not a frozen spinner.
    private func loadingProgress(_ vm: SongsListViewModel) -> some View {
        VStack(spacing: CassetteSpacing.m) {
            ProgressView()
            Text(vm.loadedCount == 0 ? "Loading songs…" : "\(vm.loadedCount.formatted()) songs loaded…")
                .font(.cassetteBody)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut, value: vm.loadedCount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func songList(_ vm: SongsListViewModel) -> some View {
        let songs = vm.displaySongs
        return ScrollViewReader { proxy in
            List {
                if vm.didTruncate {
                    Text("Showing the first \(songs.count.formatted()) songs.")
                        .font(.cassetteCaption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                cloudMusicHeader(vm, songs: songs)
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index + 1, showCoverArt: true, isFavorite: isFavorite(song))
                        .contentShape(Rectangle())
                        .onTapGesture { play(songs, at: index) }
                        .id(song.id)
                }
            }
            .listStyle(.plain)
            .miniPlayerBottomMargin()
            .refreshable { await vm.load(sort: songSort) }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                // The A–Z jump bar only makes sense when sorted by title.
                if songSort == .title && songs.count >= 20 {
                    AlphabetJumpBar(
                        availableLetters: songs.availableAlphabetLetters(keyPath: \.title),
                        onLetterTap: { letter in
                            if let id = firstAlphabetItemID(forLetter: letter, in: songs, keyPath: \.title) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                    )
                    .padding(.trailing, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func cloudMusicHeader(_ vm: SongsListViewModel, songs: [DisplayableSong]) -> some View {
        let localSongs = songs.filter(\.isDownloaded)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                    Image(systemName: "music.note.list")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text("在线歌曲")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("\(songs.count.formatted()) 首歌曲 · 已下载 \(localSongs.count.formatted()) 首")
                        .font(.cassetteCaption)
                        .foregroundStyle(.white.opacity(0.78))
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    Task { try? await container?.playerService.play(tracks: songs, startIndex: 0) }
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)

                Button {
                    Task { @MainActor in
                        guard !localSongs.isEmpty else { return }
                        do {
                            try await container?.playerService.play(tracks: localSongs, startIndex: 0)
                        } catch {
                            container?.toastService.showError("Unable to play downloaded songs.")
                        }
                    }
                } label: {
                    Label("Play Local", systemImage: "iphone.and.arrow.forward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(localSongs.isEmpty)
            }

            Button {
                Task { @MainActor in
                    let failures = await vm.downloadAll()
                    if failures == 0 {
                        container?.toastService.showSuccess("All songs are available offline")
                    } else {
                        container?.toastService.showError("\(failures) songs could not be downloaded")
                    }
                }
            } label: {
                HStack {
                    if vm.isDownloadingAll {
                        ProgressView().tint(.white)
                        Text("Downloading \(vm.downloadCompletedCount)/\(vm.downloadTotalCount)")
                    } else if localSongs.count == songs.count {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Download All", systemImage: "arrow.down.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(vm.isDownloadingAll || localSongs.count == songs.count || container?.serverState.isOnline != true)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.92, green: 0.16, blue: 0.18), Color(red: 0.72, green: 0.05, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .shadow(color: Color.red.opacity(0.18), radius: 14, y: 7)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.vertical, 8)
    }

    private func isFavorite(_ song: DisplayableSong) -> Bool {
        container?.favoritesService.isFavorite(itemType: .song, itemId: song.id) == true
    }

    private func play(_ songs: [DisplayableSong], at index: Int) {
        Task {
            do {
                try await container?.playerService.play(tracks: songs, startIndex: index)
            } catch {
                Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
            }
        }
    }
}
