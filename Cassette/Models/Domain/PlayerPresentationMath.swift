// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// UI-only normalization. Never writes to the playback engine.
nonisolated enum PlayerPresentationMath {
    static func duration(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite && seconds > 0 ? seconds : 0
    }

    static func position(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(max(0, seconds), self.duration(duration))
    }

    static func timeLabel(_ seconds: TimeInterval) -> String {
        // Bound conversion before Int.init: malformed metadata must not trap the player UI.
        let total = Int(min(duration(seconds), 359_999))
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A monotonic, pauseable rotation clock. Supply systemUptime, not wall-clock time.
/// Pausing snapshots the angle; resuming does not reset it or add time spent suspended.
nonisolated struct VinylRotationClock {
    private(set) var restingAngle: Double = 0
    private(set) var startedAt: TimeInterval?

    func angle(at now: TimeInterval) -> Double {
        guard now.isFinite, now >= 0, let startedAt else { return restingAngle }
        let elapsed = max(0, now - startedAt)
        // Reduce before multiplying to stay finite, even with extreme test inputs.
        return (restingAngle + elapsed.truncatingRemainder(dividingBy: 20) * 18)
            .truncatingRemainder(dividingBy: 360)
    }

    mutating func setRunning(_ running: Bool, at now: TimeInterval) {
        guard now.isFinite, now >= 0 else { return }
        if running {
            if startedAt == nil { startedAt = now }
        } else {
            restingAngle = angle(at: now)
            startedAt = nil
        }
    }
}
