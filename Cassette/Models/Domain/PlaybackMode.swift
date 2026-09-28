// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftUI

/// Unified playback mode exposed to the UI as a single three-state toggle.
///
/// Collapses the previous orthogonal `repeatMode` (off/all/one) + `isShuffled` (Bool)
/// pair into one cycle:
///   - `.list`   — sequential play, stop at end of queue.
/// - `.single` — repeat the current track forever.
/// - `.shuffle` — shuffle the remaining queue, stop at end.
///
/// The underlying engine still runs on `repeatMode` + `isShuffled`; `PlayerState.playbackMode`
/// derives this value from those two fields and `PlayerService.setPlaybackMode(_:)` keeps them
/// in sync (including reordering the queue when entering/leaving shuffle).
nonisolated enum PlaybackMode: String, Sendable, Codable, CaseIterable {
    case list
    case single
    case shuffle

    /// Cycles through the three states for a single tap-to-advance toggle.
    var next: PlaybackMode {
        switch self {
        case .list:    return .single
        case .single:  return .shuffle
        case .shuffle: return .list
        }
    }

    var systemImage: String {
        switch self {
        case .list:    return "list.bullet"
        case .single:  return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .list:    return "List"
        case .single:  return "Repeat One"
        case .shuffle: return "Shuffle"
        }
    }

    /// Plain String for use in accessibility labels and other non-localized contexts.
    var accessibilityLabel: String {
        switch self {
        case .list:    return "List"
        case .single:  return "Repeat One"
        case .shuffle: return "Shuffle"
        }
    }

    /// Whether this mode loops a single track (used to gate auto-extend, mirroring the old loop guard).
    var isLoopMode: Bool {
        switch self {
        case .single: return true
        case .list, .shuffle: return false
        }
    }
}
