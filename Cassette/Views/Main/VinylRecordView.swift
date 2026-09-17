// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI

/// Vector record and tonearm; no third-party artwork or animation dependency.
struct VinylRecordView: View {
    let coverArtId: String
    let diameter: CGFloat
    let isPlaying: Bool
    let isVisible: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = VinylRotationClock()

    private var shouldRotate: Bool {
        isPlaying && isVisible && scenePhase == .active && !reduceMotion
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.045))
                .frame(width: diameter + 14, height: diameter + 14)
                .overlay { Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1) }
                .offset(y: 20)

            // Timeline invalidation stays inside the record, not the lyrics/queue/player page.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldRotate)) { _ in
                record
                    .rotationEffect(.degrees(clock.angle(at: ProcessInfo.processInfo.systemUptime)))
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.5), radius: 24, y: 16)
            .offset(y: 20)

            VinylTonearm()
                .frame(width: diameter * 0.30, height: diameter * 0.62)
                .rotationEffect(.degrees(isPlaying ? -12 : -38), anchor: UnitPoint(x: 0.5, y: 0.06))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: isPlaying)
                .position(x: diameter * 0.72, y: diameter * 0.25)
        }
        .frame(width: diameter, height: diameter + 56)
        .onChange(of: shouldRotate, initial: true) { _, running in
            clock.setRunning(running, at: ProcessInfo.processInfo.systemUptime)
        }
        .onDisappear { clock.setRunning(false, at: ProcessInfo.processInfo.systemUptime) }
        .accessibilityHidden(true)
    }

    private var record: some View {
        ZStack {
            Circle().fill(Color(white: 0.055))
            Circle().fill(AngularGradient(
                colors: [.white.opacity(0.02), .white.opacity(0.18), .clear,
                         .white.opacity(0.10), .black.opacity(0.2), .white.opacity(0.02)],
                center: .center, startAngle: .degrees(0), endAngle: .degrees(360)
            ))
            ForEach(0..<12, id: \.self) { ring in
                Circle()
                    .strokeBorder(.white.opacity(ring.isMultiple(of: 3) ? 0.10 : 0.04), lineWidth: 1)
                    .padding(CGFloat(ring) * diameter * 0.013 + 5)
            }
            CoverArtView(id: coverArtId, size: 600)
                .frame(width: diameter * 0.62, height: diameter * 0.62)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.black.opacity(0.5), lineWidth: 5) }
            Circle().fill(.black.opacity(0.75)).frame(width: 14, height: 14)
            Circle().fill(Color(white: 0.75)).frame(width: 5, height: 5)
        }
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
    }
}

private struct VinylTonearm: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: w * 0.5, y: h * 0.06))
                    path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.42))
                    path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.83))
                }
                .stroke(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.4)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.82))
                    .frame(width: w * 0.16, height: h * 0.16)
                    .rotationEffect(.degrees(25))
                    .position(x: w * 0.18, y: h * 0.83)
                Circle().fill(Color(white: 0.18))
                    .frame(width: 22, height: 22)
                    .overlay { Circle().strokeBorder(Color(white: 0.7), lineWidth: 3) }
                    .position(x: w * 0.5, y: h * 0.06)
            }
            .shadow(color: .black.opacity(0.4), radius: 3, y: 3)
        }
    }
}
#endif
