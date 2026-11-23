// MusicTrack.swift
// One track, as the music UI leg and the player leg both use it.
// `sourceID` is the platform code (`wy`/`tx`/`kg`/`kw`/`mg`);
// `id` is the platform song id. The resolver derives its
// `platform|songId` identity from these two fields (the Flutter
// `identityKey` convention).

import Foundation

/// Music platform codes, shared by search, resolvers and the LX engine.
enum MusicPlatform: String, CaseIterable {
    case wy
    case tx
    case kg
    case kw
    case mg

    var displayName: String {
        switch self {
        case .wy: return "网易云音乐"
        case .tx: return "QQ音乐"
        case .kg: return "酷狗音乐"
        case .kw: return "酷我音乐"
        case .mg: return "咪咕音乐"
        }
    }

    init?(code: String) {
        self.init(rawValue: code)
    }
}

struct MusicTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let coverURL: URL?
    let duration: TimeInterval?
    /// Platform code: `wy` / `tx` / `kg` / `kw` / `mg`.
    let sourceID: String

    var platform: MusicPlatform? { MusicPlatform(code: sourceID) }

    /// Resolver identity: `platform|songId` (Flutter `identityKey`).
    /// A track with an empty song id falls back to title+artist so
    /// it still has a stable identity for cache keys.
    var identityKey: String {
        if id.isEmpty { return "\(sourceID)|\(title)|\(artist)" }
        return "\(sourceID)|\(id)"
    }

    /// Dedupe key for search results: platform+songId, or title+artist
    /// when the id is empty (Flutter `dedupeKey`).
    var dedupeKey: String {
        if id.isEmpty { return "\(sourceID)|\(title)|\(artist)" }
        return "\(sourceID)|\(id)"
    }

    init(id: String, title: String, artist: String, album: String = "",
         coverURL: URL? = nil, duration: TimeInterval? = nil,
         sourceID: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.coverURL = coverURL
        self.duration = duration
        self.sourceID = sourceID
    }
}
