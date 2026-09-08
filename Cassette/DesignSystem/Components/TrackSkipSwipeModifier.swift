// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Pure queue navigation used by the cover pager and its regression tests.
/// A cover swipe always changes tracks; unlike the transport's Previous button,
/// it never restarts the current song merely because playback passed three seconds.
enum TrackSkipNavigation {
    static func targetIndex(
        goNext: Bool,
        currentIndex: Int,
        queueCount: Int,
        repeatMode: RepeatMode
    ) -> Int? {
        guard queueCount > 0, (0..<queueCount).contains(currentIndex) else { return nil }

        if goNext {
            if currentIndex + 1 < queueCount { return currentIndex + 1 }
            return repeatMode == .all && queueCount > 1 ? 0 : nil
        }

        if currentIndex > 0 { return currentIndex - 1 }
        return repeatMode == .all && queueCount > 1 ? queueCount - 1 : nil
    }
}

#if os(iOS)
private struct TrackSkipSwipeModifier: ViewModifier {
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragOffset: CGFloat = 0
    @State private var isAnimatingSwipe = false

    let playerState: PlayerState
    let enabled: Bool

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let pageWidth = max(geometry.size.width, 1)
            let progress = min(abs(dragOffset) / pageWidth, 1)

            ZStack {
                if let previous = targetTrack(goNext: false) {
                    neighbourCover(previous)
                        .offset(x: -pageWidth + dragOffset)
                        .scaleEffect(0.96 + 0.04 * progress)
                }

                content
                    .offset(x: dragOffset)
                    .scaleEffect(1 - 0.04 * progress)

                if let next = targetTrack(goNext: true) {
                    neighbourCover(next)
                        .offset(x: pageWidth + dragOffset)
                        .scaleEffect(0.96 + 0.04 * progress)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            // The cover contains async image subviews and sits inside the full-player
            // presentation gesture hierarchy. Give horizontal paging priority so the
            // drag is not swallowed by either layer before direction is resolved.
            .highPriorityGesture(swipeGesture(pageWidth: pageWidth))
        }
        .onChange(of: playerState.currentTrack?.id) { _, _ in
            // A committed swipe resets after PlayerService adopts its target. External
            // track changes (transport, lock screen, auto-next) should reset immediately.
            guard !isAnimatingSwipe else { return }
            dragOffset = 0
        }
        .onChange(of: enabled) { _, newValue in
            guard !newValue else { return }
            isAnimatingSwipe = false
            dragOffset = 0
        }
    }

    @ViewBuilder
    private func neighbourCover(_ track: DisplayableSong) -> some View {
        CoverArtView(id: track.coverArtId ?? track.id, size: 1000)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
    }

    private func targetTrack(goNext: Bool) -> DisplayableSong? {
        guard let index = TrackSkipNavigation.targetIndex(
            goNext: goNext,
            currentIndex: playerState.currentIndex,
            queueCount: playerState.queue.count,
            repeatMode: playerState.repeatMode
        ), playerState.queue.indices.contains(index) else { return nil }
        return playerState.queue[index]
    }

    private func swipeGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard enabled, !isAnimatingSwipe, !playerState.isLiveStream else { return }

                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height) else { return }

                let goNext = horizontal < 0
                let hasTarget = targetTrack(goNext: goNext) != nil
                // At queue boundaries the cover still acknowledges the gesture, but
                // heavy rubber-banding makes it clear there is no hidden blank page.
                dragOffset = hasTarget ? horizontal : horizontal * 0.16
            }
            .onEnded { value in
                guard enabled, !isAnimatingSwipe, !playerState.isLiveStream else {
                    resetWithoutAnimation()
                    return
                }

                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height) else {
                    bounceBack()
                    return
                }

                let goNext = horizontal < 0
                guard targetTrack(goNext: goNext) != nil else {
                    HapticFeedback.light.trigger()
                    bounceBack()
                    return
                }

                let distanceThreshold = min(max(pageWidth * 0.22, 64), 110)
                let projected = value.predictedEndTranslation.width
                let crossedDistance = abs(horizontal) >= distanceThreshold
                let projectedAcrossPage = abs(projected) >= pageWidth * 0.42

                if crossedDistance || projectedAcrossPage {
                    commitSwipe(goNext: goNext, pageWidth: pageWidth)
                } else {
                    bounceBack()
                }
            }
    }

    private func commitSwipe(goNext: Bool, pageWidth: CGFloat) {
        guard let targetIndex = TrackSkipNavigation.targetIndex(
            goNext: goNext,
            currentIndex: playerState.currentIndex,
            queueCount: playerState.queue.count,
            repeatMode: playerState.repeatMode
        ) else {
            bounceBack()
            return
        }

        let queue = playerState.queue
        isAnimatingSwipe = true
        HapticFeedback.medium.trigger()

        let exitOffset = goNext ? -pageWidth : pageWidth
        let pageAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .snappy(duration: 0.24, extraBounce: 0.02)
        withAnimation(pageAnimation) {
            dragOffset = exitOffset
        }

        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(220))
            }

            guard let playerService = container?.playerService else {
                isAnimatingSwipe = false
                bounceBack()
                return
            }

            do {
                // The incoming adjacent cover is already centred at this point. Adopt
                // the corresponding queue item, then swap it into the current slot in
                // a no-animation transaction so there is no flash or reverse fly-in.
                try await playerService.play(tracks: queue, startIndex: targetIndex)
                resetWithoutAnimation()
                isAnimatingSwipe = false
            } catch {
                isAnimatingSwipe = false
                bounceBack()
            }
        }
    }

    private func bounceBack() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            dragOffset = 0
        }
    }

    private func resetWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragOffset = 0
        }
    }
}
#endif

extension View {
    func trackSkipSwipe(playerState: PlayerState, enabled: Bool = true) -> some View {
        #if os(iOS)
        modifier(TrackSkipSwipeModifier(playerState: playerState, enabled: enabled))
        #else
        self
        #endif
    }
}
