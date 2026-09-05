// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

/// Servers label the same language in wildly different ways. Matching raw strings made
/// a `zh-CN` track invisible to a `zh` system locale.
@Suite("LyricsLanguage — normalisation")
struct LyricsLanguageNormalisationTests {

    @Test func stripsRegionAndScriptSubtags() {
        #expect(LyricsLanguage.normalize("zh-CN") == "zh")
        #expect(LyricsLanguage.normalize("zh_Hans_CN") == "zh")
        #expect(LyricsLanguage.normalize("pt-BR") == "pt")
        #expect(LyricsLanguage.normalize("en-US") == "en")
    }

    @Test func mapsThreeLetterCodesToTwoLetter() {
        #expect(LyricsLanguage.normalize("zho") == "zh")
        #expect(LyricsLanguage.normalize("cmn") == "zh")
        #expect(LyricsLanguage.normalize("eng") == "en")
        #expect(LyricsLanguage.normalize("jpn") == "ja")
        #expect(LyricsLanguage.normalize("fre") == "fr")
    }

    @Test func treatsXxxAsUnd() {
        #expect(LyricsLanguage.normalize("xxx") == "und")
        #expect(LyricsLanguage.normalize("und") == "und")
    }

    @Test func isCaseInsensitive() {
        #expect(LyricsLanguage.normalize("ZH-cn") == "zh")
        #expect(LyricsLanguage.normalize("ENG") == "en")
    }

    @Test func leavesUnmappedCodesAlone() {
        // Cantonese has no 639-1 code distinct from zh's family; keep it distinct.
        #expect(LyricsLanguage.normalize("yue") == "yue")
    }

    @Test func returnsNilForUnusableInput() {
        #expect(LyricsLanguage.normalize(nil) == nil)
        #expect(LyricsLanguage.normalize("") == nil)
        #expect(LyricsLanguage.normalize("   ") == nil)
    }
}

@Suite("LyricsLanguage — matching")
struct LyricsLanguageMatchingTests {

    /// The regression this whole file exists for.
    @Test func serverRegionalTagMatchesSystemLanguage() {
        #expect(LyricsLanguage.matches("zh-CN", "zh"))
        #expect(LyricsLanguage.matches("zh-Hant", "zh"))
        #expect(LyricsLanguage.matches("eng", "en"))
        #expect(LyricsLanguage.matches("zho", "zh-CN"))
    }

    @Test func distinguishesDifferentLanguages() {
        #expect(LyricsLanguage.matches("zh-TW", "ja") == false)
        #expect(LyricsLanguage.matches("en", "fr") == false)
    }

    /// An untagged set must not win by default against a concrete language.
    @Test func unspecifiedNeverMatchesAConcreteLanguage() {
        #expect(LyricsLanguage.matches(nil, "zh") == false)
        #expect(LyricsLanguage.matches("und", "zh") == false)
        #expect(LyricsLanguage.matches("xxx", "zh") == false)
        #expect(LyricsLanguage.matches("und", "und"))
    }
}
