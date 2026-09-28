// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Single lyric line in the mainstream (Apple Music / Netease Cloud) style.
///
/// The current line is emphasised with a bold weight; every other line falls off
/// in opacity with distance from it. No blur, scale, or implicit typography animation:
/// those effects can change a wrapped line's measured height while the parent scroll view
/// is moving, allowing adjacent rows to be drawn on top of one another.
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
            .lineLimit(nil)
            // A lyric is one vertical row even when it wraps over several visual lines.
            // Fix its vertical size to the full Text layout before VStack places the next
            // row; otherwise a constrained/animated player slot can temporarily propose a
            // one-line height while Text still draws every wrapped line outside that frame.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(foregroundColor.opacity(opacity))
            // Keep row measurement and glyph drawing in the same transaction. The list's
            // scrollTo animation already supplies the motion; animating Text as well can
            // interpolate a bold line through a different wrap and leave overlap artefacts.
            .transaction { transaction in transaction.animation = nil }
            .contentShape(Rectangle())
            .onTapGesture {
                if isTappable { onTap() }
            }
    }
}
