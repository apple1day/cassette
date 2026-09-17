// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct RootView: View {
    @Environment(\.appContainer) private var container
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        Group {
            if let serverState = container?.serverState {
                if serverState.isLoadingPersistedState {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if serverState.activeServer != nil && onboardingComplete {
                    #if os(macOS)
                    RootViewMacOS()
                        .accentColor(.cassetteAccent)
                    #else
                    MainTabView()
                        .accentColor(.cassetteAccent)
                        // Cassette on iPhone is intentionally a music-first, low-glare player.
                        // Keep the song list, offline state and floating player on one dark surface.
                        .preferredColorScheme(.dark)
                    #endif
                } else {
                    OnboardingView()
                }
            }
        }
        .task(id: container?.serverState.activeServer?.id) {
            guard let container else { return }
            // Idempotent app-lifetime observers. They read the active state dynamically, so a
            // server switch only needs this task to make sure startup has happened.
            EarlySkipTracker.shared.start(
                playerState: container.playerState,
                serverState: container.serverState
            )
            DefaultShuffleTracker.shared.start(
                playerState: container.playerState,
                playerService: container.playerService
            )
        }
    }
}
