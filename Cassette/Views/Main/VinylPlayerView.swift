// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import SwiftData
import AVKit

/// iOS song presentation only. Radio keeps the existing live-stream player.
struct VinylPlayerView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let state = container?.playerState, state.isLiveStream {
            FullPlayerView()
        } else if let state = container?.playerState, let track = state.currentTrack {
            VinylSongPlayer(state: state, track: track)
        } else {
            VStack(spacing: 24) {
                ContentUnavailableView("暂无播放歌曲", systemImage: "music.note",
                                       description: Text("从歌曲列表选择一首音乐开始播放。"))
                Button("返回歌曲列表") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct VinylSongPlayer: View {
    let state: PlayerState
    let track: DisplayableSong
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var favorites: [FavoriteRecord]
    @AppStorage("cassette.player.vinylAutoLyrics") private var autoLyrics = true
    @State private var lyrics: LyricsViewModel?
    @State private var showLyrics = false
    @State private var handledAutoLyrics = false
    @State private var showQueue = false
    @State private var showVolume = false
    @State private var showAlbum = false
    @State private var playlistSong: DisplayableSong?
    @State private var errorMessage: String?
    @State private var changingTrack = false
    @State private var changingFavorite = false

    init(state: PlayerState, track: DisplayableSong) {
        self.state = state
        self.track = track
        let favoriteId = "song:\(track.id)"
        _favorites = Query(filter: #Predicate<FavoriteRecord> { $0.id == favoriteId })
    }

    private var coverId: String { track.coverArtId ?? track.id }
    private var isPlaying: Bool { state.playbackState == .playing }
    private var isOnline: Bool { container?.serverState.isOnline == true }
    private var isFavorite: Bool { !favorites.isEmpty }
    private var songKey: String {
        "\(container?.serverState.activeServer?.id.uuidString ?? "none"):\(track.id)"
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(.horizontal, 16)
                surfacePicker
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        VStack(spacing: 16) {
                            stage.frame(height: 340)
                            controls
                        }
                        .padding(.horizontal, 24)
                    }
                } else if geometry.size.width > geometry.size.height {
                    HStack(spacing: 28) {
                        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView { controls }
                            .frame(width: max(278, min(420, geometry.size.width * 0.48)))
                    }
                    .padding(.horizontal, 28)
                } else {
                    stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls.padding(.horizontal, geometry.size.width < 375 ? 16 : 28)
                }
            }
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 8)
            .background { background(size: geometry.size) }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .task(id: songKey) { await loadLyrics() }
        .onChange(of: state.position) { _, _ in autoShowLyricsIfNeeded() }
        .onDisappear { lyrics?.setVisible(false) }
        .sheet(isPresented: $showQueue) { queueSheet }
        .sheet(isPresented: $showVolume) { volumeSheet }
        .sheet(item: $playlistSong) { song in AddToPlaylistSheet(song: song) }
        .sheet(isPresented: $showAlbum) {
            if let albumId = track.albumId {
                NavigationStack {
                    AlbumDetailView(albumId: albumId, albumName: track.albumName ?? "专辑", coverArtId: track.coverArtId)
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "请稍后重试。") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            iconButton("收起播放器", symbol: "chevron.down") { dismiss() }
                .accessibilityIdentifier("player.dismiss")
            VStack(spacing: 4) {
                Text(track.title).font(.headline).lineLimit(1)
                    .accessibilityIdentifier("player.title")
                Button { navigateToArtist() } label: {
                    Text(track.artist ?? "未知歌手")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(track.artistId == nil)
                .accessibilityLabel("歌手：\(track.artist ?? "未知歌手")")
            }
            .frame(maxWidth: .infinity)
            // Share metadata only; authenticated server/stream URLs never leave the app.
            ShareLink(item: "\(track.title) — \(track.artist ?? "未知歌手")") {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }
            .accessibilityLabel("分享歌曲信息")
        }
        .frame(minHeight: 58)
    }

    private var surfacePicker: some View {
        HStack(spacing: 28) {
            surfaceButton("唱片", selected: !showLyrics) { selectLyrics(false) }
            surfaceButton("歌词", selected: showLyrics) { selectLyrics(true) }
        }
        .frame(height: 44)
    }

    private func surfaceButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                Capsule().fill(selected ? .white : .clear).frame(width: 16, height: 2)
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.45))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var stage: some View {
        GeometryReader { geometry in
            ZStack {
                if showLyrics {
                    if let lyrics {
                        LyricsView(viewModel: lyrics, foregroundColor: .white)
                            .id(songKey)
                            .padding(.horizontal, 24)
                            // No parent tap recognizer: lyric-line taps must continue to seek.
                    } else {
                        ContentUnavailableView("暂无歌词", systemImage: "text.quote",
                                               description: Text("当前歌曲没有可用的歌词数据。"))
                    }
                } else {
                    let diameter = max(80, min(360, geometry.size.width - 48, geometry.size.height - 64))
                    Button { selectLyrics(true) } label: {
                        VinylRecordView(coverArtId: coverId, diameter: diameter,
                                        isPlaying: isPlaying,
                                        isVisible: !showQueue && !showVolume && !showAlbum && playlistSong == nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看《\(track.title)》的歌词")
                    .accessibilityIdentifier("player.record")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                iconButton(isFavorite ? "取消喜欢" : "喜欢歌曲",
                           symbol: isFavorite ? "heart.fill" : "heart") { toggleFavorite() }
                    .foregroundStyle(isFavorite ? Color(red: 0.98, green: 0.28, blue: 0.32) : .white)
                    .disabled(!isOnline || changingFavorite)
                    .opacity(isOnline ? 1 : 0.35)
                Spacer(minLength: 8)
                iconButton("添加到歌单", symbol: "text.badge.plus") { playlistSong = track }
                    .disabled(!isOnline)
                    .opacity(isOnline ? 1 : 0.35)
                Spacer(minLength: 8)
                iconButton("音量与播放设备", symbol: "speaker.wave.2") { showVolume = true }
                Spacer(minLength: 8)
                moreMenu
            }
            .font(.system(size: 22, weight: .light))

            VinylSeekBar(state: state, trackId: track.id)

            HStack(spacing: 0) {
                iconButton("播放模式：\(modeTitle)", symbol: state.playbackMode == .list ? "arrow.right" : state.playbackMode.systemImage) {
                    guard let service = container?.playerService else { return }
                    Task { await service.setPlaybackMode(state.playbackMode.next) }
                }
                .font(.system(size: 23))
                .accessibilityIdentifier("player.mode")
                Spacer(minLength: 8)
                iconButton("上一首", symbol: "backward.end.fill") { skip(previous: true) }
                    .font(.system(size: 27)).disabled(changingTrack)
                Spacer(minLength: 8)
                Button {
                    guard let service = container?.playerService else { return }
                    Task { await service.togglePlayPause() }
                } label: {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.8)
                        if state.playbackState == .loading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 28))
                                .offset(x: isPlaying ? 0 : 2)
                        }
                    }
                    .frame(width: 70, height: 70).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(state.playbackState == .loading)
                .accessibilityLabel(isPlaying ? "暂停" : "播放")
                .accessibilityIdentifier("player.playPause")
                Spacer(minLength: 8)
                iconButton("下一首", symbol: "forward.end.fill") { skip(previous: false) }
                    .font(.system(size: 27)).disabled(changingTrack)
                Spacer(minLength: 8)
                iconButton("播放列表，共\(state.queue.count)首", symbol: "list.bullet") { showQueue = true }
                    .font(.system(size: 25))
                    .accessibilityIdentifier("player.queue")
            }
            .padding(.vertical, 6)

            HStack(spacing: 6) {
                if case .error = state.playbackState {
                    Label("播放失败，请重试", systemImage: "exclamationmark.circle")
                } else if state.playbackState == .loading {
                    Text("正在加载音频…")
                } else {
                    if track.isDownloaded {
                        Label("已下载", systemImage: "checkmark.circle")
                    }
                    if let format = track.audioFormat { Text(format) }
                    Text(modeTitle)
                }
            }
            .font(.caption2).foregroundStyle(.white.opacity(0.5))
            .frame(minHeight: 20)
        }
        .frame(maxWidth: 560)
        .buttonStyle(.plain)
    }

    private var modeTitle: String {
        switch state.playbackMode {
        case .list: return "顺序播放"
        case .single: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("查看专辑", systemImage: "square.stack") { showAlbum = true }
                .disabled(track.albumId == nil)
            Button("查看歌手", systemImage: "person") { navigateToArtist() }
                .disabled(track.artistId == nil)
            Divider()
            Button("相似歌曲", systemImage: "sparkles") {
                guard let container else { return }
                let song = track
                Task {
                    do { try await container.playerService.playInstantMix(from: .song(id: song.id), startingWith: song) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            .disabled(!isOnline)
            Toggle("播放15秒后显示歌词", isOn: $autoLyrics)
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .accessibilityLabel("更多歌曲操作")
    }

    private var queueSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    CoverArtView(id: coverId, size: 96).frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在播放").font(.caption).foregroundStyle(.secondary)
                        Text(track.title).font(.headline).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isPlaying ? "waveform" : "pause.fill")
                }
                .padding(.horizontal, 20)
                Toggle("播完后自动续播相似歌曲", isOn: Binding(
                    get: { state.isAutoExtendEnabled },
                    set: { enabled in Task { await container?.playerService.setAutoExtendEnabled(enabled) } }
                ))
                .font(.subheadline).padding(.horizontal, 20)
                InlineQueueList(playerState: state)
            }
            .navigationTitle("播放列表 · \(state.queue.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showQueue = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var volumeSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack {
                    Image(systemName: "speaker.fill")
                    SystemVolumeView(contentColor: .white)
                    Image(systemName: "speaker.wave.3.fill")
                }
                HStack {
                    Text("选择 AirPlay / 蓝牙设备").font(.subheadline)
                    Spacer()
                    VinylRoutePicker().frame(width: 44, height: 44)
                        .accessibilityLabel("选择播放设备")
                }
            }
            .padding(24)
            .navigationTitle("音量与设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showVolume = false } } }
        }
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
    }

    private func background(size: CGSize) -> some View {
        ZStack {
            Color(white: 0.06)
            CoverArtView(id: coverId, size: 600)
                .frame(width: size.width, height: size.height)
                .clipped().blur(radius: 65).scaleEffect(1.2).opacity(0.50)
            LinearGradient(colors: [.black.opacity(0.20), .black.opacity(0.45), .black.opacity(0.80)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title)
    }

    private func selectLyrics(_ value: Bool) {
        handledAutoLyrics = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { showLyrics = value }
    }

    private func loadLyrics() async {
        lyrics?.setVisible(false)
        lyrics = nil
        handledAutoLyrics = false
        guard let container, let serverId = container.serverState.activeServer?.id else { return }
        let model = LyricsViewModel(songId: track.id, serverId: serverId,
                                   lyricsService: container.lyricsService,
                                   playerService: container.playerService, playerState: state,
                                   title: track.title, artist: track.artist)
        lyrics = model
        await model.load()
        guard !Task.isCancelled else { model.setVisible(false); return }
        autoShowLyricsIfNeeded()
    }

    private func autoShowLyricsIfNeeded() {
        guard autoLyrics, !handledAutoLyrics, !showLyrics, !showQueue,
              !showAlbum, !showVolume, playlistSong == nil,
              isPlaying, state.position >= 15,
              let lyrics, case .loaded(let structured) = lyrics.state, structured.synced else { return }
        handledAutoLyrics = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { showLyrics = true }
    }

    private func navigateToArtist() {
        guard let artistId = track.artistId else { return }
        NotificationCenter.default.post(name: .cassetteNavigateToArtist, object: nil,
                                        userInfo: ["artistId": artistId,
                                                   "artistName": track.artist ?? "未知歌手",
                                                   "coverArtId": track.coverArtId ?? ""])
    }

    private func toggleFavorite() {
        guard let container, !changingFavorite, isOnline else { return }
        let songId = track.id
        let wasFavorite = isFavorite
        changingFavorite = true
        Task {
            defer { changingFavorite = false }
            do {
                if wasFavorite { try await container.favoritesService.unstar(itemType: .song, itemId: songId) }
                else { try await container.favoritesService.star(itemType: .song, itemId: songId) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func skip(previous: Bool) {
        guard let service = container?.playerService, !changingTrack else { return }
        changingTrack = true
        HapticFeedback.medium.trigger()
        Task {
            defer { changingTrack = false }
            do {
                if previous { try await service.skipToPrevious() }
                else { try await service.skipToNext() }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

/// Holds a drag draft separately from the engine position. Seeking happens once on release.
private struct VinylSeekBar: View {
    let state: PlayerState
    let trackId: String
    @Environment(\.appContainer) private var container
    @State private var isEditing = false
    @State private var draft: TimeInterval = 0
    @State private var editingTrackId: String?

    private var duration: TimeInterval { PlayerPresentationMath.duration(state.duration) }
    private var displayed: TimeInterval {
        PlayerPresentationMath.position(isEditing ? draft : state.position, duration: duration)
    }

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { displayed }, set: { draft = $0 }),
                   in: 0...max(duration, 1), onEditingChanged: editingChanged)
                .tint(.white.opacity(0.9)).frame(minHeight: 44)
                .disabled(duration == 0 || state.playbackState == .loading)
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(PlayerPresentationMath.timeLabel(displayed))，共\(PlayerPresentationMath.timeLabel(duration))")
                .accessibilityIdentifier("player.progress")
                .accessibilityAdjustableAction { direction in
                    guard duration > 0 else { return }
                    switch direction {
                    case .increment: seek(to: displayed + 5, for: trackId)
                    case .decrement: seek(to: displayed - 5, for: trackId)
                    @unknown default: break
                    }
                }
            HStack {
                Text(PlayerPresentationMath.timeLabel(displayed))
                Spacer()
                Text(PlayerPresentationMath.timeLabel(duration))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
        }
        .onChange(of: trackId) { _, _ in
            // A late drag-end from the previous song must never seek the next one.
            isEditing = false
            editingTrackId = nil
            draft = 0
        }
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            draft = PlayerPresentationMath.position(state.position, duration: duration)
            editingTrackId = trackId
            isEditing = true
        } else {
            let target = draft
            let originalTrack = editingTrackId
            isEditing = false
            editingTrackId = nil
            guard let originalTrack, originalTrack == trackId else { return }
            seek(to: target, for: originalTrack)
        }
    }

    private func seek(to seconds: TimeInterval, for songId: String) {
        guard duration > 0 else { return }
        let target = PlayerPresentationMath.position(seconds, duration: duration)
        Task {
            guard state.currentTrack?.id == songId else { return }
            await container?.playerService.seek(to: target)
        }
    }
}

private struct VinylRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemRed
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
