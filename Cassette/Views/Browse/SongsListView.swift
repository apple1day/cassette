// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog

/// Library-wide "All Songs" list. Pages the whole library (search3's empty-query wildcard) with a live
/// progress count, sorts off-main, and shows a Play/Shuffle-all header, a persisted sort control, and an
/// A–Z jump bar when sorted by title.
struct SongsListView: View {
    @Environment(\.appContainer) private var container
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
        .navigationTitle("Songs")
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
        if vm.isLoading && vm.displaySongs.isEmpty {
            loadingProgress(vm)
        } else if container?.serverState.isOnline == false && vm.displaySongs.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                subtitle: "Connect to your server to browse all songs."
            )
        } else if let error = vm.error, vm.displaySongs.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Songs",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load(sort: songSort) } }
            )
        } else if vm.displaySongs.isEmpty {
            EmptyStateView(
                systemImage: "music.note",
                title: "No Songs",
                subtitle: "Your library appears to be empty."
            )
        } else {
            songList(vm)
        }
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
                    Text("All Songs")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("\(songs.count.formatted()) songs · \(localSongs.count.formatted()) downloaded")
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
