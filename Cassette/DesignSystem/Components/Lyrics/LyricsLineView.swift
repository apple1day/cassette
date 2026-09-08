// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Single lyric line in the mainstream (Apple Music / Netease Cloud) style.
///
/// The current line is emphasised with a bold weight; every other line falls off
/// in opacity with distance from it. No blur and no per-line scale — blurring text
/// near the list's top/bottom fade produced a ghosted "double image", and scaling the
/// current line made the stack shift as the index advanced. Opacity + weight only keeps a
/// clean, readable, non-shifting column that stays legible over the gradient mask.
struct LyricsLineView: View {
    let value: String
    let index: Int
    let currentIndex: Int?
    let isSynced: Bool
    let isTappable: Bool
    var foregroundColor: Color = .white
    let onTap: () -> Void

    private var distance: Int {
        guard let currentIndex else { return 0 }
        return abs(index - currentIndex)
    }

    /// Whether this line is the currently-played one. Unsynced lyrics never emphasise
    /// a single line (there is no timing to follow), so the whole block stays uniform.
    private var isCurrent: Bool {
        isSynced && index == currentIndex
    }

    /// Opacity falloff from the current line. Kept as a smooth curve: the current line is
    /// fully opaque, the immediate neighbours drop to ~½, and lines further away settle
    /// on a readable floor (never fully invisible, so the user can skim ahead/back).
    private var opacity: Double {
        guard isSynced, currentIndex != nil else { return 1.0 }
        switch distance {
        case 0: return 1.0
        case 1: return 0.55
        case 2: return 0.32
        default: return 0.18
        }
    }

    var body: some View {
        Text(value)
            .font(.system(.title, design: .rounded, weight: isCurrent ? .bold : .regular))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(foregroundColor.opacity(opacity))
            // Weight/opacity animate as the index advances; font size is constant so the row
            // height never changes and the stack doesn't jump (that jump read as ghosting too).
            .animation(.easeInOut(duration: 0.2), value: currentIndex)
            .contentShape(Rectangle())
            .onTapGesture {
                if isTappable { onTap() }
            }
    }
}
