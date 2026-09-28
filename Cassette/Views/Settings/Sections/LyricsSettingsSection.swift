// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Toggle for showing the current lyric line in the now-playing title (CarPlay / car head units
/// that render only the track title). Backs `cassette.player.lyricsInNowPlaying`, consumed by
/// ``NowPlayingLyricsCoordinator``; defaults to on.
struct LyricsSettingsSection: View {
    @AppStorage("cassette.player.lyricsInNowPlaying") private var showLyricsInNowPlaying = true

    var body: some View {
        Section {
            Toggle(isOn: $showLyricsInNowPlaying) {
                Label {
                    Text("Show lyrics in Now Playing")
                } icon: {
                    SettingsIcon(systemImage: "quote.bubble.fill", color: .pink)
                }
            }
        } header: {
            Text("Lyrics")
        } footer: {
            Text("Replaces the song title with the current lyric line in the now playing info. CarPlay and car head units that only show the track title then display the lyrics.")
        }
    }
}
