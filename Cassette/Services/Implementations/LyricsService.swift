// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

/// Fetches and caches lyrics for the active server.
///
/// The fetch is deliberately **optimistic** — capability declarations are treated as
/// advisory and never gate the request. Servers routinely under-report what they
/// support, and SwiftSonic degrades to an empty extension map whenever
/// `getOpenSubsonicExtensions` fails, caching that empty result for the client's
/// lifetime. Gating on capabilities meant one transient failure could disable lyrics
/// permanently.
///
/// Instead the service tries every source in turn and only reports failure when all
/// of them come back empty:
///
/// 1. Fresh cache (or stale cache when the network is unreachable)
/// 2. `getLyricsBySongId` — OpenSubsonic `songLyrics`, structured and optionally synced
/// 3. `getLyrics(artist:title:)` — legacy plain text, parsed by ``LyricsParser``
///
/// Step 3 is what rescues Navidrome libraries that store `.lrc` files beside the audio
/// or lyrics inside tags: those frequently answer only through the legacy endpoint,
/// which Cassette never called before.
///
/// All persistence uses a private ModelContext created per operation.
/// No UIKit or SwiftUI imports — this actor is platform-agnostic.
actor LyricsService {
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer

    init(serverService: any ServerServiceProtocol, modelContainer: ModelContainer) {
        self.serverService = serverService
        self.modelContainer = modelContainer
    }

    // MARK: - Cache lifetime

    /// How long a cached result stays fresh, by quality of what it contains.
    ///
    /// Unsynced lyrics get the short lease: a server that later picks up a `.lrc` file
    /// would otherwise stay invisible for as long as the entry lives.
    private static let syncedTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let unsyncedTTL: TimeInterval = 24 * 60 * 60
    /// Empty results are remembered briefly so re-opening the player for a track with
    /// no lyrics doesn't re-hit the network every time.
    private static let negativeTTL: TimeInterval = 6 * 60 * 60

    // MARK: - Fetch

    /// Returns lyrics for a song, trying every available source.
    ///
    /// - Parameters:
    ///   - songId:   The server-side song id.
    ///   - serverId: Active server, part of the cache key.
    ///   - title:    Song title, used only by the legacy `getLyrics` fallback.
    ///   - artist:   Song artist, used only by the legacy `getLyrics` fallback.
    /// - Returns: A non-empty ``LyricsList``.
    /// - Throws: ``LyricsError/notFound`` when every source came back empty,
    ///           ``LyricsError/notSupportedByServer`` when the server rejects the endpoint
    ///           outright, or ``LyricsError/networkError(underlying:)`` when the network
    ///           failed with no cache to fall back on.
    func fetchLyrics(
        forSongId songId: String,
        serverId: UUID,
        title: String? = nil,
        artist: String? = nil
    ) async throws -> LyricsList {
        let cache = await cachedEntry(songId: songId, serverId: serverId)
        if let cache, isFresh(cache) {
            Logger.lyrics.debug("Cache hit — songId=\(songId, privacy: .public)")
            return cache.list
        }

        let client = try await serverService.makeSwiftSonicClient()
        await logCapabilities(of: client)

        var list = LyricsList()
        var endpointUnsupported = false
        var transportError: Error?

        do {
            list = try await client.getLyricsBySongId(id: songId)
        } catch let error as SwiftSonicError where error.indicatesUnsupportedEndpoint {
            endpointUnsupported = true
            Logger.lyrics.info("getLyricsBySongId unsupported by server — \(error.localizedDescription, privacy: .public)")
        } catch {
            transportError = error
            Logger.lyrics.warning("getLyricsBySongId failed — songId=\(songId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        list = Self.droppingPlaceholders(list)

        if list.structuredLyrics.isEmpty {
            list = await legacyFallback(from: client, title: title, artist: artist) ?? LyricsList()
        }

        guard !list.structuredLyrics.isEmpty else {
            // A transport failure with nothing new to show is a connectivity problem,
            // not an empty library — report it as such so the UI can offer a retry.
            if let transportError {
                if let cache {
                    Logger.lyrics.info("Network error, returning stale cache — songId=\(songId, privacy: .public)")
                    return cache.list
                }
                throw LyricsError.networkError(underlying: transportError.localizedDescription)
            }

            await persistLyrics(LyricsList(), songId: songId, serverId: serverId)
            throw endpointUnsupported ? LyricsError.notSupportedByServer : LyricsError.notFound
        }

        await persistLyrics(list, songId: songId, serverId: serverId)
        return list
    }

    /// Drops the cached entry for a song so the next fetch goes to the network.
    ///
    /// Call this before a user-initiated retry — otherwise the negative cache set by a
    /// previous empty result would keep serving "no lyrics".
    func invalidate(songId: String, serverId: UUID) async {
        let key = cacheKey(songId: songId, serverId: serverId)
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedLyrics>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        guard let existing = (try? context.fetch(descriptor))?.first else { return }
        context.delete(existing)
        try? context.save()
        Logger.lyrics.debug("Invalidated cache — songId=\(songId, privacy: .public)")
    }

    // MARK: - Legacy fallback

    /// Recovers lyrics through the legacy `getLyrics` endpoint.
    ///
    /// Subsonic servers return whatever they happen to have here — often the `.lrc`
    /// file verbatim, or the contents of an embedded lyrics tag. ``LyricsParser`` turns
    /// timestamped text into synced lines and everything else into unsynced ones, so
    /// content that previously could only be shown as one block now scrolls properly.
    ///
    /// Downloader placeholder files (`[00:00.00]暂无歌词`) are rejected: they parse
    /// fine, but rendering them would show "暂无歌词" as the song's only lyric.
    ///
    /// - Returns: `nil` when the endpoint has nothing, when it fails, when no
    ///            title/artist was supplied to query with, or when the payload is a
    ///            placeholder.
    private func legacyFallback(
        from client: SwiftSonicClient,
        title: String?,
        artist: String?
    ) async -> LyricsList? {
        guard let title, !title.isEmpty else { return nil }

        guard let legacy = try? await client.getLyrics(artist: artist, title: title),
              let value = legacy.value else { return nil }

        if LyricsParser.isPlaceholder(value) {
            Logger.lyrics.info("Legacy payload is a downloader placeholder — treating as no lyrics")
            return nil
        }

        guard let parsed = LyricsParser.parse(value, lang: nil) else { return nil }

        Logger.lyrics.info("Recovered lyrics via legacy getLyrics — synced=\(parsed.synced, privacy: .public), lines=\(parsed.line.count, privacy: .public)")
        return LyricsList(structuredLyrics: [parsed])
    }

    /// Removes structured entries whose only content is placeholder text.
    ///
    /// NetEase-style downloaders write `[00:00.00]暂无歌词` files next to tracks that
    /// have no lyrics at the source; the server serves those as perfectly valid synced
    /// lyrics. Rendering them shows the placeholder as the song's only line — worse than
    /// showing nothing, because it looks like a lyric.
    private static func droppingPlaceholders(_ list: LyricsList) -> LyricsList {
        guard list.structuredLyrics.contains(where: { LyricsParser.isPlaceholder($0) }) else {
            return list
        }

        let kept = list.structuredLyrics.filter { !LyricsParser.isPlaceholder($0) }
        Logger.lyrics.info("Dropped \(list.structuredLyrics.count - kept.count, privacy: .public) placeholder lyric set(s)")
        return LyricsList(structuredLyrics: kept)
    }

    // MARK: - Capabilities (advisory only)

    /// Logs what the server claims to support, and repairs a silently degraded probe.
    ///
    /// When SwiftSonic cannot read `getOpenSubsonicExtensions` it swallows the error and
    /// leaves the extension map empty, then caches that for the client's lifetime. A
    /// single failure — or a reverse proxy that blocks the endpoint — would report "no
    /// OpenSubsonic extensions" forever. Seeing an empty map on a server that claims to
    /// be OpenSubsonic is therefore worth exactly one forced refresh.
    ///
    /// The result is logged for diagnosis and never used to block a request.
    private func logCapabilities(of client: SwiftSonicClient) async {
        guard var capabilities = try? await client.loadCapabilities() else {
            Logger.lyrics.debug("Capabilities unavailable — proceeding with optimistic fetch")
            return
        }

        if capabilities.isOpenSubsonic, capabilities.extensions.isEmpty {
            Logger.lyrics.info("Empty extension map on an OpenSubsonic server — forcing one refresh")
            if let refreshed = try? await client.refreshCapabilities() {
                capabilities = refreshed
            }
        }

        Logger.lyrics.debug("Server — type=\(capabilities.serverType ?? "unknown", privacy: .public) version=\(capabilities.serverVersion ?? "?", privacy: .public) openSubsonic=\(capabilities.isOpenSubsonic, privacy: .public) songLyrics=\(capabilities.supports(.songLyrics), privacy: .public) extensions=\(capabilities.extensions.count, privacy: .public)")
    }

    // MARK: - Language Selection

    /// Picks the best StructuredLyrics set for the given locale and optional user preference.
    ///
    /// Priority:
    /// 1. User-selected `preferred` language — synced variant if available, else unsynced.
    /// 2. System locale language — synced variant if available, else unsynced.
    /// 3. Any synced set, then first available.
    ///
    /// Comparison goes through ``LyricsLanguage``, so `zh-CN`, `zh-Hans`, `zho` and
    /// `cmn` all satisfy a `zh` system locale. Raw string equality silently dropped
    /// those matches and fell through to whichever set happened to be synced.
    nonisolated func selectBestLanguage(
        from list: LyricsList,
        locale: Locale = .current,
        preferred: String? = nil
    ) -> StructuredLyrics? {
        let entries = list.structuredLyrics
        guard !entries.isEmpty else { return nil }

        func best(among candidates: [StructuredLyrics]) -> StructuredLyrics? {
            candidates.first(where: { $0.synced }) ?? candidates.first
        }

        if let preferred {
            let matching = entries.filter { LyricsLanguage.matches($0.lang, preferred) }
            if let hit = best(among: matching) { return hit }
        }

        let langCode = locale.language.languageCode?.identifier ?? ""
        if !langCode.isEmpty {
            let matching = entries.filter { LyricsLanguage.matches($0.lang, langCode) }
            if let hit = best(among: matching) { return hit }
        }

        return entries.first(where: { $0.synced }) ?? entries.first
    }

    // MARK: - Private cache

    /// A decoded cache entry plus the timestamp it was written at.
    ///
    /// Value type on purpose: `CachedLyrics` is a SwiftData model and must not escape
    /// this actor.
    private struct CacheEntry {
        let list: LyricsList
        let fetchedAt: Date
    }

    private func isFresh(_ entry: CacheEntry) -> Bool {
        let age = Date().timeIntervalSince(entry.fetchedAt)
        if entry.list.structuredLyrics.isEmpty { return age < Self.negativeTTL }
        if entry.list.structuredLyrics.contains(where: { $0.synced }) { return age < Self.syncedTTL }
        return age < Self.unsyncedTTL
    }

    private func cacheKey(songId: String, serverId: UUID) -> String {
        "\(serverId.uuidString):\(songId)"
    }

    private func cachedEntry(songId: String, serverId: UUID) async -> CacheEntry? {
        let key = cacheKey(songId: songId, serverId: serverId)
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedLyrics>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        guard let entry = (try? context.fetch(descriptor))?.first else { return nil }
        do {
            let payload = entry.jsonPayload
            let fetchedAt = entry.fetchedAt
            let list = try await MainActor.run { try JSONDecoder().decode(LyricsList.self, from: payload) }
            return CacheEntry(list: list, fetchedAt: fetchedAt)
        } catch {
            Logger.lyrics.error("Cache corrupted — key=\(key, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    private func persistLyrics(_ list: LyricsList, songId: String, serverId: UUID) async {
        let data = try? await MainActor.run { try JSONEncoder().encode(list) }
        guard let data else { return }
        let key = cacheKey(songId: songId, serverId: serverId)
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedLyrics>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            context.delete(existing)
        }
        context.insert(CachedLyrics(songId: songId, serverId: serverId, jsonPayload: data))
        try? context.save()
        let count = list.structuredLyrics.count
        Logger.lyrics.debug("Persisted lyrics — songId=\(songId, privacy: .public), sets=\(count, privacy: .public)")
    }
}

// MARK: - SwiftSonicError classification

extension SwiftSonicError {
    /// True when the failure means this server does not implement the endpoint at all.
    ///
    /// Distinct from "the endpoint worked but has no data for this song" — a
    /// `notFound` (70) API error means the latter and must keep the legacy fallback in
    /// play. Only transport-level rejections qualify here: a 404/501, or a generic
    /// server-side complaint that offers no better explanation.
    var indicatesUnsupportedEndpoint: Bool {
        switch self {
        case .httpError(let statusCode, _, _):
            return statusCode == 404 || statusCode == 400 || statusCode == 501
        case .api(let error):
            switch error.code {
            case .generic, .unknown, .clientMustUpgrade, .serverMustUpgrade:
                return true
            default:
                return false
            }
        case .network, .decoding, .rateLimited, .invalidConfiguration, .insecureRedirect:
            return false
        }
    }
}
