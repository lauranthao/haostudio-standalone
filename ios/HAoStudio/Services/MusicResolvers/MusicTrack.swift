// MusicTrack.swift
// One track, as the music UI leg and the player leg both use it.
// `sourceID` is the platform code (`wy`/`tx`/`kg`/`kw`/`mg`);
// `id` is the platform song id. The resolver derives its
// `platform|songId` identity from these two fields (the Flutter
// `identityKey` convention).

import Foundation

/// Music platform codes, shared by search, resolvers and the LX engine.
/// `mg` (Migu) is resolver-only: no mg search exists (Flutter music_models.dart).
enum MusicPlatform: String, CaseIterable {
    case wy
    case tx
    case kg
    case kw
    case mg

    init?(code: String) {
        self.init(rawValue: code)
    }

    /// Map a code to a platform, defaulting to wy for unknown codes
    /// (Flutter fromCode behaviour).
    static func fromCode(_ code: String?) -> MusicPlatform {
        switch code {
        case "tx": return .tx
        case "kg": return .kg
        case "kw": return .kw
        case "mg": return .mg
        case "wy": fallthrough
        default: return .wy
        }
    }

    /// Map an LX/search `sourceID` to a platform for badges. Known
    /// platform codes map directly; an LX script id (e.g. "lx:…") has
    /// no platform signal, so it falls back to wy — the badge then
    /// shows 网易, which is wrong for a script result. (Known gap:
    /// the LX leg should carry the platform on MusicTrack if badges
    /// must be exact for script results.)
    static func fromSourceID(_ sourceID: String?) -> MusicPlatform {
        return fromCode(sourceID)
    }

    /// Short badge shown on song rows (Flutter badgeName).
    var badgeName: String {
        switch self {
        case .wy: return "网易"
        case .tx: return "QQ"
        case .kg: return "酷狗"
        case .kw: return "酷我"
        case .mg: return "咪咕"
        }
    }

    var displayName: String {
        switch self {
        case .wy: return "网易云"
        case .tx: return "QQ音乐"
        case .kg: return "酷狗音乐"
        case .kw: return "酷我"
        case .mg: return "咪咕"
        }
    }

    /// Search merge order wy/tx/kg/kw (Flutter kSearchPlatforms).
    var searchPriority: Int {
        switch self {
        case .wy: return 0
        case .tx: return 1
        case .kg: return 2
        case .kw: return 3
        case .mg: return 4
        }
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
