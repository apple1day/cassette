// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Turns raw lyrics text into a ``StructuredLyrics`` value.
///
/// Subsonic-family servers surface lyrics in three shapes, and Cassette used to
/// consume only the first one:
///
/// | Source | Shape | Who decodes it |
/// |--------|-------|----------------|
/// | `getLyricsBySongId` (OpenSubsonic `songLyrics`) | Structured, optional per-line timing | SwiftSonic |
/// | `getLyrics` (legacy) — server returns the `.lrc` file verbatim | LRC text with `[mm:ss.xx]` stamps | ``LyricsParser`` |
/// | `getLyrics` (legacy) — server returns an embedded tag | Plain text, no timing | ``LyricsParser`` (unsynced) |
///
/// A Navidrome library that stores `.lrc` files next to the audio, or lyrics baked into
/// tags, frequently answers only through the legacy endpoint. Without this parser that
/// content could only ever be shown as one opaque block, or not at all.
///
/// - Note: Pure `Foundation` + `SwiftSonic` — no UIKit/SwiftUI, safe to unit test and to
///   call from the `LyricsService` actor.
enum LyricsParser {

    // MARK: - Public API

    /// Parses raw lyrics text into structured, optionally time-synced lines.
    ///
    /// The input may be LRC (`[00:12.34]text`), LRC with metadata tags
    /// (`[ti:]` / `[ar:]` / `[offset:]`), or plain text with no timing at all.
    ///
    /// - Parameters:
    ///   - raw:   The lyrics text exactly as the server returned it.
    ///   - lang:  Language tag to attach, when the caller knows one.
    /// - Returns: A ``StructuredLyrics`` value, or `nil` when `raw` holds no renderable
    ///            content (empty, whitespace-only, or metadata tags only).
    static func parse(_ raw: String, lang: String? = nil) -> StructuredLyrics? {
        let timedLines = parseTimedLines(from: raw)
        let metadata = parseMetadata(from: raw)

        if !timedLines.isEmpty {
            return StructuredLyrics(
                lang: lang,
                synced: true,
                line: timedLines,
                displayArtist: metadata.artist,
                displayTitle: metadata.title,
                offset: metadata.offset
            )
        }

        let plainLines = parsePlainLines(from: raw)
        guard !plainLines.isEmpty else { return nil }

        return StructuredLyrics(
            lang: lang,
            synced: false,
            line: plainLines,
            displayArtist: metadata.artist,
            displayTitle: metadata.title,
            offset: 0
        )
    }

    /// True when `raw` contains at least one parseable LRC timestamp.
    ///
    /// Lets callers cheaply decide whether a legacy payload is worth running through
    /// ``parse(_:lang:)`` as synced content.
    static func hasTimestamps(_ raw: String) -> Bool {
        !parseTimedLines(from: raw).isEmpty
    }

    // MARK: - Placeholder detection

    /// Texts downloaders write into `.lrc` files when the source has no lyrics.
    ///
    /// NetEase-style tools save `[00:00.00]暂无歌词` as a stand-in file; the server then
    /// happily serves it as synced lyrics and the player renders "暂无歌词" as the song's
    /// only line. Anything in this set, when it is *all* the file contains, means "no
    /// lyrics" — not content.
    private static let placeholderTexts: Set<String> = [
        "暂无歌词",
        "纯音乐",
        "纯音乐，请欣赏",
        "此歌曲为纯音乐，请欣赏",
        "此歌曲为没有填词的纯音乐，请欣赏",
        "暂无歌词，请欣赏",
    ]

    /// True when `raw` carries no real content — every line it holds is a known
    /// downloader placeholder (`暂无歌词` and friends).
    ///
    /// A file that mixes placeholder text with actual lyrics is *not* a placeholder;
    /// only an all-placeholder payload is.
    static func isPlaceholder(_ raw: String) -> Bool {
        let texts = placeholderCandidates(in: raw)
        guard !texts.isEmpty else { return false }
        return texts.allSatisfy { placeholderTexts.contains($0) }
    }

    /// Same check on an already-parsed set — used to prune server-side structured
    /// entries whose only content is placeholder text.
    static func isPlaceholder(_ structured: StructuredLyrics) -> Bool {
        let texts = structured.line
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return false }
        return texts.allSatisfy { placeholderTexts.contains($0) }
    }

    /// Every visible text the raw payload holds, with timestamps, metadata tags, and
    /// JSON wrappers stripped — the material ``isPlaceholder(_:)`` judges.
    private static func placeholderCandidates(in raw: String) -> [String] {
        var texts: [String] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{") {
                if let text = netEaseJSONLineText(line) { texts.append(text) }
                continue
            }

            // Strip leading `[..]` groups — timestamps and metadata tags alike.
            var cursor = line.startIndex
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break }
                cursor = line.index(after: close)
            }
            let text = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { texts.append(text) }
        }

        return texts
    }

    // MARK: - Timed lines

    /// Extracts every timestamped line, in chronological order.
    ///
    /// A single line may carry several timestamps — LRC uses that to share one verse
    /// across repeats (`[00:12.00][01:20.00]Chorus`). Each timestamp becomes its own
    /// ``Line`` so scrolling stays correct on every pass.
    ///
    /// NetEase-style JSON fragments (`{"t":1234,"c":[{"tx":"text"}]}`) are accepted too:
    /// downloaders frequently prepend a few of them — the credits lines — in front of
    /// standard LRC content. Treating the whole file as broken over them would throw
    /// away the good lines that follow.
    ///
    /// On ties at the same timestamp, LRC lines sort before JSON. NetEase files use
    /// negative `t` (clamped to 0) for credits, so they frequently tie with the title
    /// line at `[00:00.00]`; putting the title first reads more naturally.
    private static func parseTimedLines(from raw: String) -> [Line] {
        struct Ranked {
            let line: Line
            let kind: Int   // 0 = LRC, 1 = JSON credits
        }

        var result: [Ranked] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("{") {
                if let parsed = parseNetEaseJSONLine(line) {
                    result.append(Ranked(line: parsed, kind: 1))
                }
                continue
            }

            var stamps: [Int] = []
            var cursor = line.startIndex

            // Walk leading [..] groups, keeping the ones that look like timestamps.
            // The first non-timestamp group ends the scan — everything after it is lyric text.
            scan: while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break scan }
                let inner = String(line[line.index(after: cursor)..<close])

                if let ms = timestampMilliseconds(inner) {
                    stamps.append(ms)
                    cursor = line.index(after: close)
                } else {
                    break scan
                }
            }

            guard !stamps.isEmpty else { continue }

            let text = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
            // LRC ends instrumental sections with an empty timestamped line; keep them so
            // the highlighted line advances through the gap instead of sticking on the
            // previous verse.
            for stamp in stamps {
                result.append(Ranked(line: Line(value: text, start: stamp), kind: 0))
            }
        }

        // Servers occasionally emit out-of-order stamps; the tracker assumes ascending order.
        return result
            .sorted { ($0.line.start ?? 0, $0.kind) < ($1.line.start ?? 0, $1.kind) }
            .map { $0.line }
    }

    /// Converts an LRC timestamp body (`"01:23.45"`) to milliseconds.
    ///
    /// Accepts `mm:ss`, `mm:ss.xx`, `mm:ss.xxx`, and the `mm:ss:xx` variant some
    /// taggers emit. Fractional digits are normalised by width, so `.5`, `.50`, and
    /// `.500` all mean the same thing.
    ///
    /// - Returns: `nil` when the body is not a timestamp (e.g. `ti:Song title`).
    private static func timestampMilliseconds(_ body: String) -> Int? {
        // The separator between minutes and seconds is ":" — the fractional part is
        // introduced by "." in standard LRC, or by a second ":" in the less common variant.
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let minutes = Int(parts[0]), minutes >= 0 else { return nil }

        let secondsPart: Substring
        let fractionPart: Substring?

        if parts.count == 3 {
            secondsPart = parts[1]
            fractionPart = parts[2]
        } else if let dot = parts[1].firstIndex(of: ".") {
            secondsPart = parts[1][..<dot]
            fractionPart = parts[1][parts[1].index(after: dot)...]
        } else {
            secondsPart = parts[1]
            fractionPart = nil
        }

        guard let seconds = Int(secondsPart), seconds >= 0, seconds < 60 else { return nil }

        var millis = 0
        if let fractionPart {
            guard let parsed = fractionMilliseconds(fractionPart) else { return nil }
            millis = parsed
        }

        return ((minutes * 60) + seconds) * 1000 + millis
    }

    /// Scales an LRC fractional-seconds field to milliseconds, whatever its width.
    ///
    /// Widening `.5` to 500 ms keeps taggers that trim trailing zeros comparable with
    /// those that don't.
    private static func fractionMilliseconds(_ fraction: Substring) -> Int? {
        guard !fraction.isEmpty, let value = Int(fraction) else { return nil }
        switch fraction.count {
        case 1:  return value * 100
        case 2:  return value * 10
        case 3:  return value
        default: return value / Int(pow(10.0, Double(fraction.count - 3)))
        }
    }

    // MARK: - NetEase JSON lines

    /// Decodes one NetEase-style JSON lyric fragment into a timed line.
    ///
    /// Shape: `{"t":12340,"c":[{"tx":"故事的小黄花"}]}` — `t` is the line start in
    /// milliseconds (occasionally negative for pre-roll credits), `c` holds text chunks
    /// that concatenate into the line. Returns `nil` for anything that is not this shape,
    /// so malformed fragments are skipped instead of poisoning the timeline.
    private static func parseNetEaseJSONLine(_ line: String) -> Line? {
        guard let text = netEaseJSONLineText(line), let start = netEaseJSONLineStart(line) else {
            return nil
        }
        return Line(value: text, start: start)
    }

    /// Concatenated text of a NetEase JSON fragment, or `nil` when it carries none.
    private static func netEaseJSONLineText(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let chunks = dictionary["c"] as? [[String: Any]] else { return nil }

        let text = chunks.compactMap { $0["tx"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Line start in milliseconds from a NetEase JSON fragment, or `nil` when missing
    /// or not numeric. Negative values are clamped to zero — the player treats them as
    /// "before the song started", which would otherwise stick the highlight off-screen.
    private static func netEaseJSONLineStart(_ line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let start = dictionary["t"] as? Int else { return nil }
        return max(start, 0)
    }

    // MARK: - Plain lines

    /// Splits untimed lyrics into per-line values, dropping metadata tags and blank lines.
    ///
    /// Consecutive blank lines are preserved as a single empty line so paragraph breaks
    /// survive — collapsing them turns a verse separator into nothing at all.
    private static func parsePlainLines(from raw: String) -> [Line] {
        var result: [Line] = []
        var lastWasBlank = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(rawLine).trimmingCharacters(in: .whitespaces)

            if text.isEmpty {
                if !result.isEmpty && !lastWasBlank {
                    result.append(Line(value: ""))
                }
                lastWasBlank = true
                continue
            }

            if isMetadataTag(text) { continue }

            lastWasBlank = false
            result.append(Line(value: text))
        }

        // A trailing empty line adds no meaning.
        if result.last?.value.isEmpty == true { result.removeLast() }
        return result
    }

    // MARK: - Metadata

    private struct Metadata {
        var title: String?
        var artist: String?
        var offset: Int = 0
    }

    /// Reads LRC metadata tags: `ti`, `ar`, and `offset`.
    ///
    /// **Offset sign convention.** LRC and OpenSubsonic disagree here. In LRC a positive
    /// offset makes lyrics appear *sooner*; ``LyricsViewModel/update(elapsedMs:)`` applies
    /// `adjusted = elapsed - offset`, so a positive OpenSubsonic offset *delays* a line.
    /// The sign is therefore flipped when translating.
    private static func parseMetadata(from raw: String) -> Metadata {
        var metadata = Metadata()

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }

            let inner = String(line[line.index(after: line.startIndex)..<close])
            let parts = inner.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "ti":
                metadata.title = value
            case "ar":
                metadata.artist = value
            case "offset":
                // LRC offsets are whole milliseconds, optionally signed.
                if let lrcOffset = Int(value) {
                    metadata.offset = -lrcOffset
                }
            default:
                break
            }
        }

        return metadata
    }

    /// True for `[key:value]` metadata tags, as opposed to `[mm:ss.xx]` timestamps.
    private static func isMetadataTag(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        let inner = String(line[line.index(after: line.startIndex)..<close])
        return timestampMilliseconds(inner) == nil
    }
}
