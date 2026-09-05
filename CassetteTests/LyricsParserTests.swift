// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

/// Covers the parser that rescues lyrics served through the legacy `getLyrics`
/// endpoint — the path Navidrome uses for `.lrc` files and embedded tags.
@Suite("LyricsParser — timed (LRC) content")
struct LyricsParserTimedTests {

    @Test func parsesTimestampsAndMetadata() {
        let lrc = """
        [ti:Title]
        [ar:Artist]
        [offset:+500]
        [00:12.34]first line
        [00:15.67][01:20.00]shared line

        [00:20.00]
        """
        let parsed = LyricsParser.parse(lrc, lang: "zh-CN")!

        #expect(parsed.synced)
        #expect(parsed.line.count == 4)
        #expect(parsed.line[0].value == "first line")
        #expect(parsed.line[0].start == 12_340)
        #expect(parsed.displayTitle == "Title")
        #expect(parsed.displayArtist == "Artist")
        // LRC positive offset means "appear sooner"; Cassette's tracker applies
        // adjusted = elapsed - offset, so a positive OpenSubsonic offset delays a line.
        #expect(parsed.offset == -500)
    }

    /// A verse repeated later reuses one line of text with two timestamps.
    @Test func expandsSharedTimestampsAndSorts() {
        let lrc = "[00:15.67][01:20.00]shared line\n[00:20.00]later"
        let parsed = LyricsParser.parse(lrc)!

        #expect(parsed.line.map { $0.start } == [15_670, 20_000, 80_000])
        #expect(parsed.line[0].value == "shared line")
        #expect(parsed.line[2].value == "shared line")
    }

    /// Servers occasionally emit stamps out of order; the tracker assumes ascending.
    @Test func sortsOutOfOrderTimestamps() {
        let parsed = LyricsParser.parse("[00:30.00]third\n[00:10.00]first\n[00:20.00]second")!
        #expect(parsed.line.map { $0.start } == [10_000, 20_000, 30_000])
    }

    @Test func acceptsTimestampWidthVariants() {
        let parsed = LyricsParser.parse("[01:02.345]a\n[00:05]b\n[00:06:50]c")!

        #expect(parsed.line.map { $0.start } == [5_000, 6_500, 62_345])
    }

    /// Taggers trim trailing zeros inconsistently; all three must agree.
    @Test func normalisesFractionalWidths() {
        let parsed = LyricsParser.parse("[00:01.5]a\n[00:02.50]b\n[00:03.500]c")!
        #expect(parsed.line.map { $0.start } == [1_500, 2_500, 3_500])
    }

    /// An out-of-range seconds field makes the whole line untimed rather than wrong.
    @Test func rejectsImpossibleSeconds() {
        #expect(LyricsParser.parse("[00:99.00]x") == nil)
    }

    @Test func hasTimestampsDistinguishesLrcFromPlainText() {
        #expect(LyricsParser.hasTimestamps("[00:12.34]line"))
        #expect(LyricsParser.hasTimestamps("just words") == false)
    }
}

@Suite("LyricsParser — untimed content")
struct LyricsParserPlainTests {

    @Test func splitsPlainTextIntoLines() {
        let plain = "[ti:Untimed]\nfirst line\nsecond line\n\nsecond verse\n"
        let parsed = LyricsParser.parse(plain)!

        #expect(parsed.synced == false)
        #expect(parsed.line.count == 4)
        #expect(parsed.offset == 0)
        // The blank line survives as a paragraph break.
        #expect(parsed.line[2].value == "")
        #expect(parsed.line.contains { $0.value.contains("[ti:") } == false)
    }

    @Test func returnsNilForEmptyOrMetadataOnlyInput() {
        #expect(LyricsParser.parse("") == nil)
        #expect(LyricsParser.parse("   \n \n") == nil)
        #expect(LyricsParser.parse("[ti:x]\n[ar:y]") == nil)
    }
}

@Suite("LyricsParser — NetEase JSON lyric fragments")
struct LyricsParserNetEaseJSONTests {

    /// NetEase downloaders prepend a few JSON credits lines (`{"t":-1000,"c":[...]}`)
    /// before the `[mm:ss.xx]line` content. Without this support those files would render
    /// the credits as garbage text lines instead of timed lyrics.
    @Test func parsesHybridFileAndPlacesTitleFirst() {
        let hybrid = """
        {"t":-1000,"c":[{"tx":"作词: "},{"tx":"0"}]}
        {"t":-500,"c":[{"tx":"作曲: "},{"tx":"0"}]}
        [00:00.00]爱是无畏的冒险-程今
        [00:01.30]词：T1
        """
        let parsed = LyricsParser.parse(hybrid)!

        #expect(parsed.synced)
        // 5 timed entries: title + 4 credits lines (negative `t` clamped to 0).
        #expect(parsed.line.count == 5)
        // LRC wins ties over JSON credits, so the title line comes first.
        #expect(parsed.line[0].value == "爱是无畏的冒险-程今")
        #expect(parsed.line[1].value == "作词: 0")
        #expect(parsed.line[2].value == "作曲: 0")
        #expect(parsed.line[3].start == 1_300)
    }

    @Test func handlesNegativeStartByClampingToZero() {
        let json = #"{"t":-1000,"c":[{"tx":"pre-roll"}]}"#
        let line = LyricsParser.parse(json)!.line.first!

        #expect(line.start == 0)
        #expect(line.value == "pre-roll")
    }

    /// A JSON fragment without `t` is unsynced — only the text shape matches, the
    /// timing data is missing.
    @Test func missingStartFallsBackToUnsyncedText() {
        let json = #"{"c":[{"tx":"untimed"}]}"#
        let parsed = LyricsParser.parse(json)!

        #expect(parsed.synced == false)
        #expect(parsed.line.first?.value == json)
    }

    /// A JSON fragment without `c` carries no text — nothing to render, falls through
    /// to unsynced with the raw JSON as the only line.
    @Test func missingChunksFallsBackToUnsynced() {
        let json = #"{"t":12345}"#
        let parsed = LyricsParser.parse(json)!

        #expect(parsed.synced == false)
    }
}

@Suite("LyricsParser — downloader placeholder detection")
struct LyricsParserPlaceholderTests {

    /// The exact pattern NetEase writes when a song has none at the source.
    @Test func recognisesNetEasePlaceholder() {
        #expect(LyricsParser.isPlaceholder("[00:00.00]暂无歌词"))
        #expect(LyricsParser.isPlaceholder("[00:00.00]纯音乐，请欣赏"))
        #expect(LyricsParser.isPlaceholder("[00:00.00]此歌曲为没有填词的纯音乐，请欣赏"))
    }

    @Test func recognisesPlainTextPlaceholder() {
        #expect(LyricsParser.isPlaceholder("暂无歌词"))
        #expect(LyricsParser.isPlaceholder("纯音乐"))
    }

    /// A file that mixes placeholder text with actual lyrics is *not* a placeholder —
    /// the real lyrics are still worth rendering.
    @Test func mixedPlaceholderAndRealContentIsNotAPlaceholder() {
        let mixed = """
        [00:00.00]暂无歌词
        [00:30.00]this is a real lyric
        """
        #expect(LyricsParser.isPlaceholder(mixed) == false)
    }

    @Test func recognisesPlaceholderStructuredEntry() {
        let placeholder = StructuredLyrics(
            lang: "zh-CN", synced: true, line: [Line(value: "暂无歌词", start: 0)]
        )
        #expect(LyricsParser.isPlaceholder(placeholder))

        let real = StructuredLyrics(
            lang: "zh-CN", synced: true, line: [Line(value: "爱是无畏的冒险", start: 0)]
        )
        #expect(LyricsParser.isPlaceholder(real) == false)
    }
}
