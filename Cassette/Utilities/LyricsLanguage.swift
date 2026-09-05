// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Normalises language tags so server-supplied values can be compared with
/// `Locale` language codes.
///
/// Servers are inconsistent about which standard they speak. Navidrome and the
/// metadata extractors behind it have been observed emitting `zh`, `zh-CN`,
/// `zh-Hans`, `zho`, `cmn`, `eng`, and `xxx` for what is effectively the same
/// language. The previous matcher compared raw strings for equality, so a
/// `zh-CN` track never matched a `zh` system locale and silently fell through
/// to whichever set happened to be synced — usually English or romanised text.
enum LyricsLanguage {

    /// Reduces a language tag to a comparable two-letter code.
    ///
    /// Applied to both server values and system locale codes, so both sides land
    /// on the same key:
    ///
    /// - `xxx` → `und` (both mean "unspecified" in the OpenSubsonic spec)
    /// - Region and script subtags are dropped: `zh-CN`, `zh-Hant` → `zh`
    /// - ISO 639-2/3 three-letter codes map to 639-1: `eng` → `en`, `zho` → `zh`
    /// - Legacy/duplicate codes collapse: `iw` → `he`, `in` → `id`, `ji` → `yi`
    ///
    /// - Returns: `nil` when the input carries no usable language
    ///   (`nil`, empty, or `und`/`xxx` with nothing else to go on).
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }

        // Drop the script/region part first: "zh-Hans-CN" -> "zh".
        let primary = raw
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""

        guard !primary.isEmpty else { return nil }
        guard primary != "xxx", primary != "und" else { return "und" }

        if let mapped = threeLetterToTwoLetter[primary] { return mapped }
        return primary
    }

    /// True when two language tags refer to the same language after normalisation.
    ///
    /// `nil` is treated as "unspecified" and never matches a concrete language —
    /// otherwise every untagged lyric set would win by default.
    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalize(lhs), let rhs = normalize(rhs) else { return false }
        return lhs == rhs
    }

    // MARK: - ISO 639-2 / 639-3 → 639-1

    /// Coverage is deliberately broad for the languages music libraries actually
    /// contain, rather than exhaustive for all ~180 ISO 639-1 codes.
    private static let threeLetterToTwoLetter: [String: String] = [
        // Chinese varieties — all collapse to zh so a zh-Hant track matches a zh locale.
        "zho": "zh", "cmn": "zh", "chi": "zh",
        // The remaining CJK + major Asian languages.
        "jpn": "ja", "kor": "ko", "tha": "th", "vie": "vi", "ind": "id",
        "msa": "ms", "may": "ms", "tgl": "tl", "fil": "tl",
        // Western European.
        "eng": "en", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
        "spa": "es", "por": "pt", "ita": "it", "nld": "nl", "dut": "nl",
        "swe": "sv", "nor": "no", "nob": "no", "nno": "no", "dan": "da",
        "fin": "fi", "isl": "is", "ice": "is", "gle": "ga", "cym": "cy",
        "wel": "cy", "cat": "ca", "glg": "gl", "eus": "eu", "baq": "eu",
        // Central & South-Eastern European.
        "pol": "pl", "ces": "cs", "cze": "cs", "slk": "sk", "slo": "sk",
        "hun": "hu", "ron": "ro", "rum": "ro", "bul": "bul", "hrv": "hr",
        "srp": "sr", "slv": "sl", "lit": "lt", "lav": "lv", "est": "et",
        "ukr": "uk", "bel": "be", "mkd": "mk", "mac": "mk", "alb": "sq",
        "sqi": "sq", "bos": "bs",
        // The rest.
        "rus": "ru", "ell": "el", "gre": "el", "tur": "tr", "heb": "he",
        "ara": "ar", "fas": "fa", "per": "fa", "hin": "hi", "ben": "bn",
        "tam": "ta", "tel": "te", "mar": "mr", "guj": "gu", "kan": "kn",
        "mal": "ml", "urd": "ur", "nep": "ne", "sin": "si", "kat": "ka",
        "geo": "ka", "hye": "hy", "arm": "hy", "aze": "az", "kaz": "kk",
        "uzb": "uz", "afr": "af", "swa": "sw", "zul": "zu",
        // Legacy ISO 639-1 codes superseded in 1989, still emitted by old taggers.
        "iw": "he", "in": "id", "ji": "yi", "jaw": "jw"
    ]
}
