// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct MainTabView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var searchPath = NavigationPath()
    @State private var homePath = NavigationPath()
    @State private var selectedTab: AppTab = .home
    @State private var showingFullPlayer = false
    @Namespace private var playerZoom
    private let fullPlayerZoomID = "full-player"

    private enum AppTab: Hashable { case home, discover, search }

    private var hasTrack: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            tabs
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    if hasTrack {
                        MiniPlayerAccessoryView(showingFullPlayer: $showingFullPlayer)
                            .environment(\.colorScheme, colorScheme)
                            .cassetteMatchedTransitionSource(id: fullPlayerZoomID, in: playerZoom)
                    }
                }
                .fullScreenCover(isPresented: $showingFullPlayer) {
                    FullPlayerView()
                        .cassetteZoomTransition(sourceID: fullPlayerZoomID, in: playerZoom)
                }
        } else {
            // iOS 18: no tabViewBottomAccessory API. Keep the player as a dedicated
            // floating surface above the tab bar. A solid dark surface keeps controls
            // legible over artwork and song rows instead of inheriting the content
            // behind a translucent material.
            tabs
                .safeAreaInset(edge: .bottom) {
                    if hasTrack {
                        MiniPlayerAccessoryView(showingFullPlayer: $showingFullPlayer)
                            .environment(\.colorScheme, .dark)
                            .cassetteMatchedTransitionSource(id: fullPlayerZoomID, in: playerZoom)
                            .background(
                                Color(red: 0.13, green: 0.13, blue: 0.16),
                                in: RoundedRectangle(cornerRadius: CassetteCornerRadius.hero)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.hero))
                            .overlay {
                                RoundedRectangle(cornerRadius: CassetteCornerRadius.hero)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                            .padding(.horizontal, CassetteSpacing.s)
                            // Lift clear of the tab bar (safeAreaInset draws over it), plus a small gap.
                            .padding(.bottom, CassetteSpacing.legacyTabBarHeight + CassetteSpacing.xs)
                    }
                }
                .fullScreenCover(isPresented: $showingFullPlayer) {
                    FullPlayerView()
                        .cassetteZoomTransition(sourceID: fullPlayerZoomID, in: playerZoom)
                }
        }
        #else
        tabs
            .safeAreaInset(edge: .bottom) {
                if hasTrack { MiniPlayerAccessoryView(showingFullPlayer: $showingFullPlayer) }
            }
            .sheet(isPresented: $showingFullPlayer) {
                FullPlayerView()
            }
        #endif
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("歌曲", systemImage: "music.note", value: AppTab.home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                }
            }

            Tab("我的", systemImage: "person.fill", value: AppTab.discover) {
                NavigationStack {
                    SettingsView()
                }
            }

            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(searchQuery: $searchText, path: $searchPath)
                        .navigationTitle("搜索")
                }
                .searchable(text: $searchText, prompt: "搜索歌曲、歌手、专辑…")
            }
        }
        .accentColor(.cassetteAccent)

        .task(id: container?.serverState.isOnline) {
            guard container?.serverState.isOnline == true else { return }
            try? await container?.favoritesService.syncFromServer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToArtist)) { note in
            guard let id   = note.userInfo?["artistId"]   as? String,
                  let name = note.userInfo?["artistName"] as? String else { return }
            let coverArtId = note.userInfo?["coverArtId"] as? String
            showingFullPlayer = false
            selectedTab = .home
            homePath.append(HomeDestination.artistById(id: id, name: name, coverArtId: coverArtId))
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToPlaylist)) { note in
            guard let id   = note.userInfo?["playlistId"] as? String,
                  let name = note.userInfo?["name"]       as? String else { return }
            let coverArtId = note.userInfo?["coverArtId"] as? String
            showingFullPlayer = false
            selectedTab = .home
            homePath.append(HomeDestination.playlistById(id: id, name: name, coverArtId: coverArtId))
        }
    }
}
