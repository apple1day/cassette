// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

// TODO(v1.x): consider TTL or LRU eviction if storage grows.
@Model
final class CachedLyrics {
    /// Versioned because parser/timing semantics affect the encoded payload. Bumping
    /// the prefix safely leaves old rows unreachable and refreshes them on demand.
    @Attribute(.unique) var compositeKey: String  // "v2:{serverId}:{songId}"
    var songId: String
    var serverId: UUID
    var jsonPayload: Data  // serialized LyricsList — see LyricsEncoding.swift for Encodable conformance
    var fetchedAt: Date

    init(songId: String, serverId: UUID, jsonPayload: Data) {
        self.compositeKey = "v2:\(serverId.uuidString):\(songId)"
        self.songId = songId
        self.serverId = serverId
        self.jsonPayload = jsonPayload
        self.fetchedAt = Date()
    }
}
