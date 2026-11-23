// HAo Studio 2.0 — music models (S2-C leg).
//
// Swift equivalents of the Flutter 1.1.6 music JSON shapes
// (lib/services/music/music_models.dart, HEAD 2ef902b). Field names and
// key rules are copied exactly so the S1-migrated JSON files
// (Documents/hao_fav.json, hao_recent.json, …) read back without
// re-migration. Durations are ALWAYS seconds.
//
// Parsing is tolerant on purpose: a bad number type or a missing field
// yields a default, never a crash — a corrupt collection must never
// crash launch (same rule as LocalStore.loadCollection).
//
// Contract types used here (owned by the player / LX legs, NOT defined
// in this file): MusicTrack { id, title, artist, album, coverURL,
// duration, sourceID }.

import Foundation

/// Music platforms. `mg` (Migu) is resolver-only: no mg search exists
/// (Flutter music_models.dart).
enum MusicPlatform: String, CaseIterable {
    case wy
    case tx
    case kg
    case kw
    case mg

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
    /// shows 网易, which is wrong for a script result. Contract gap:
    /// the LX leg should carry the platform on MusicTrack if badges
    /// must be exact for script results (see the C-leg report).
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

/// Tolerant JSON field readers. Numbers may arrive as Int, Double or
/// numeric strings (Flutter wrote ints; the migration re-encoded via
/// JSONSerialization, which keeps numbers as NSNumber).
enum MusicJSON {
    static func string(_ dict: [String: Any], _ key: String) -> String {
        if let value = dict[key] as? String { return value }
        if let value = dict[key] as? NSNumber { return value.stringValue }
        return ""
    }

    static func int(_ dict: [String: Any], _ key: String) -> Int {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? Double { return Int(value) }
        if let value = dict[key] as? NSNumber { return value.intValue }
        if let value = dict[key] as? String { return Int(value) ?? 0 }
        return 0
    }

    static func double(_ dict: [String: Any], _ key: String) -> Double {
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        if let value = dict[key] as? NSNumber { return value.doubleValue }
        if let value = dict[key] as? String { return Double(value) ?? 0 }
        return 0
    }

    static func bool(_ dict: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
        if let value = dict[key] as? Bool { return value }
        if let value = dict[key] as? NSNumber { return value.boolValue }
        return defaultValue
    }

    static func array(_ dict: [String: Any], _ key: String) -> [[String: Any]] {
        guard let raw = dict[key] as? [[String: Any]] else { return [] }
        return raw
    }

    /// Parse a top-level JSON document that must be an array of objects.
    static func objectArray(from data: Data) -> [[String: Any]] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [[String: Any]] else { return [] }
        return array
    }

    /// Parse a top-level JSON document that must be an object.
    static func object(from data: Data) -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = parsed as? [String: Any] else { return [:] }
        return dict
    }

    /// Encode a top-level Array/Dictionary to JSON data. NEVER call
    /// with a top-level String: JSONSerialization throws an NSException
    /// ("Invalid top-level type in JSON write") that Swift cannot catch
    /// and the app crashes. Callers here only ever pass arrays/dicts.
    static func data(forTopLevel value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [])
    }
}

/// One song (Flutter `Song`). JSON keys are the Flutter toJson keys.
struct MusicSong: Equatable, Identifiable {
    var songId: String
    var title: String
    var artist: String
    var album: String
    var cover: String
    var platform: MusicPlatform
    /// Duration in seconds.
    var dur: Int
    var albumYear: Int
    var reasonKey: String
    var reasonArg: String
    /// Stored path of a local audio file, empty for remote songs.
    var localPath: String

    var id: String { identityKey }

    init(
        songId: String = "",
        title: String = "",
        artist: String = "",
        album: String = "",
        cover: String = "",
        platform: MusicPlatform = .wy,
        dur: Int = 0,
        albumYear: Int = 0,
        reasonKey: String = "",
        reasonArg: String = "",
        localPath: String = ""
    ) {
        self.songId = songId
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.platform = platform
        self.dur = dur
        self.albumYear = albumYear
        self.reasonKey = reasonKey
        self.reasonArg = reasonArg
        self.localPath = localPath
    }

    init(json: [String: Any]) {
        self.init(
            songId: MusicJSON.string(json, "songId"),
            title: MusicJSON.string(json, "title"),
            artist: MusicJSON.string(json, "artist"),
            album: MusicJSON.string(json, "album"),
            cover: MusicJSON.string(json, "cover"),
            platform: MusicPlatform.fromCode(json["platform"] as? String),
            dur: MusicJSON.int(json, "dur"),
            albumYear: MusicJSON.int(json, "albumYear"),
            reasonKey: MusicJSON.string(json, "reasonKey"),
            reasonArg: MusicJSON.string(json, "reasonArg"),
            localPath: MusicJSON.string(json, "localPath")
        )
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "songId": songId,
            "title": title,
            "artist": artist,
            "album": album,
            "cover": cover,
            "platform": platform.rawValue,
            "dur": dur,
            "albumYear": albumYear,
            "reasonKey": reasonKey,
            "reasonArg": reasonArg,
        ]
        if !localPath.isEmpty { dict["localPath"] = localPath }
        return dict
    }

    /// Identity key for favourites / recent / listen log / resume.
    /// A song with an empty songId MUST NOT share a key with every
    /// other empty-id song on the same platform: empty ids fall back
    /// to title+artist+album (Flutter identityKey, verbatim).
    var identityKey: String {
        if !songId.isEmpty { return "\(platform.rawValue)|\(songId)" }
        return "\(platform.rawValue)|\(title)|\(artist)|\(album)"
    }

    /// Dedupe key for aggregated search: platform + songId; empty id
    /// falls back to title+artist (Flutter dedupeKey, verbatim).
    var dedupeKey: String {
        if !songId.isEmpty { return "\(platform.rawValue)|\(songId)" }
        return "\(platform.rawValue)||\(title)|\(artist)"
    }

    /// True for an imported local file (songId starts with 'local:'
    /// AND a path is stored — both must hold).
    var isLocal: Bool { !localPath.isEmpty && songId.hasPrefix("local:") }

    /// Convert a contract MusicTrack (LX leg) to a local song.
    /// Assumed MusicTrack field types (see the C-leg report):
    /// coverURL is a String, duration is Int seconds.
    init(from track: MusicTrack) {
        self.init(
            songId: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            cover: track.coverURL,
            platform: MusicPlatform.fromSourceID(track.sourceID),
            dur: track.duration
        )
    }

    /// The playback item for this song (coordinator contract).
    func toPlaybackItem() -> PlaybackItem {
        PlaybackItem(id: songId.isEmpty ? identityKey : songId, kind: .music, title: title, artist: artist)
    }
}

/// One user playlist (Flutter `UserPlaylist`).
struct UserPlaylist: Equatable, Identifiable {
    var id: String
    var name: String
    var tracks: [MusicSong]

    var trackCount: Int { tracks.count }
    var cover: String { tracks.first?.cover ?? "" }

    init(id: String = "", name: String = "", tracks: [MusicSong] = []) {
        self.id = id
        self.name = name
        self.tracks = tracks
    }

    init(json: [String: Any]) {
        self.init(
            id: MusicJSON.string(json, "id"),
            name: MusicJSON.string(json, "name"),
            tracks: MusicJSON.array(json, "tracks").map(MusicSong.init(json:))
        )
    }

    func toJSON() -> [String: Any] {
        return ["id": id, "name": name, "tracks": tracks.map { $0.toJSON() }]
    }

    /// Add songs, skipping true duplicates (same identityKey) and
    /// stopping at 1000 tracks (Flutter addTracks / maxTracksPerList).
    /// Returns (added, dropped, dupes).
    mutating func addTracks(_ incoming: [MusicSong]) -> (added: Int, dropped: Int, dupes: Int) {
        var seen = Set(tracks.map { $0.identityKey })
        var added = 0
        var dropped = 0
        var dupes = 0
        for song in incoming {
            if !seen.insert(song.identityKey).inserted {
                dupes += 1
                continue
            }
            if tracks.count >= 1000 {
                dropped += 1
                continue
            }
            tracks.append(song)
            added += 1
        }
        return (added, dropped, dupes)
    }
}

/// One downloaded song (Flutter `DownloadedSong`).
struct DownloadedSong: Equatable {
    var song: MusicSong
    /// Stored file reference (relative name `music_downloads/<file>`
    /// or a legacy absolute path — resolved via LocalFileIndex).
    var filePath: String
    var sizeBytes: Int
    var downloadedAt: Int
    /// Quality code the file was downloaded at ('master' / 'hires' /
    /// 'lossless' / '320k' / '128k'). Pre-tier entries have no field:
    /// hires is the safe default — never over-claim Master.
    var qualityCode: String

    var key: String { song.identityKey }
    var fileName: String { URL(fileURLWithPath: filePath).lastPathComponent }

    /// The downloaded tier as a coordinator AudioQuality.
    var quality: AudioQuality {
        switch qualityCode {
        case "master": return .master
        case "lossless": return .flac
        case "320k": return .high320
        case "128k": return .standard128
        case "hires": fallthrough
        default: return .hiRes
        }
    }

    init(json: [String: Any]) {
        let songJSON = json["song"] as? [String: Any] ?? [:]
        self.song = MusicSong(json: songJSON)
        self.filePath = MusicJSON.string(json, "filePath")
        self.sizeBytes = MusicJSON.int(json, "sizeBytes")
        self.downloadedAt = MusicJSON.int(json, "downloadedAt")
        let code = MusicJSON.string(json, "quality")
        self.qualityCode = code.isEmpty ? "hires" : code
    }

    func toJSON() -> [String: Any] {
        return [
            "song": song.toJSON(),
            "filePath": filePath,
            "sizeBytes": sizeBytes,
            "downloadedAt": downloadedAt,
            "quality": qualityCode,
        ]
    }
}

/// One listen event (Flutter `ListenEvent`, hao_listen).
/// `dur` is seconds actually heard; `totalDur` is the full song
/// length (0 = unknown); `at` is epoch milliseconds.
struct ListenEvent: Equatable {
    var songId: String
    var title: String
    var artist: String
    var platform: MusicPlatform
    var cover: String
    var dur: Int
    var totalDur: Int
    var at: Int

    init(json: [String: Any]) {
        self.songId = MusicJSON.string(json, "songId")
        self.title = MusicJSON.string(json, "title")
        self.artist = MusicJSON.string(json, "artist")
        self.platform = MusicPlatform.fromCode(json["platform"] as? String)
        self.cover = MusicJSON.string(json, "cover")
        self.dur = MusicJSON.int(json, "dur")
        self.totalDur = MusicJSON.int(json, "totalDur")
        self.at = MusicJSON.int(json, "at")
    }

    func toJSON() -> [String: Any] {
        return [
            "songId": songId,
            "title": title,
            "artist": artist,
            "platform": platform.rawValue,
            "cover": cover,
            "dur": dur,
            "totalDur": totalDur,
            "at": at,
        ]
    }
}

/// One cached lyric line (Flutter `LyricLine` JSON: t / text /
/// translation). Kept separate from the LX leg's contract `LyricsLine`
/// (time / text) so the two shapes never collide; the player view
/// model converts stored lines to contract lines when showing them.
struct StoredLyricLine: Equatable {
    /// Time in seconds.
    var t: Double
    var text: String
    var translation: String?

    init(t: Double, text: String, translation: String? = nil) {
        self.t = t
        self.text = text
        self.translation = translation
    }

    init(json: [String: Any]) {
        self.t = MusicJSON.double(json, "t")
        self.text = MusicJSON.string(json, "text")
        let translation = MusicJSON.string(json, "translation")
        self.translation = translation.isEmpty ? nil : translation
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = ["t": t, "text": text]
        if let translation = translation { dict["translation"] = translation }
        return dict
    }
}

/// Playback queue as stored in Documents/musicQueue.json
/// (`{songs, index}`, Flutter musicQueue).
struct MusicQueueData {
    var songs: [MusicSong]
    var index: Int

    init(songs: [MusicSong] = [], index: Int = 0) {
        self.songs = songs
        self.index = index
    }

    init(json: [String: Any]) {
        self.songs = MusicJSON.array(json, "songs").map(MusicSong.init(json:))
        self.index = MusicJSON.int(json, "index")
    }

    func toJSON() -> [String: Any] {
        return ["songs": songs.map { $0.toJSON() }, "index": index]
    }
}

/// `M月d日 星期X` date line for the music home (Flutter homeDateText).
func musicHomeDateText(_ now: Date) -> String {
    let calendar = Calendar.current
    let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
    let weekday = calendar.component(.weekday, from: now)
    let month = calendar.component(.month, from: now)
    let day = calendar.component(.day, from: now)
    return "\(month)月\(day)日 \(weekdays[(weekday - 1) % 7])"
}

/// Day key `YYYY-MM-DD` (Flutter dayKeyOf).
func musicDayKey(of date: Date) -> String {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    return String(format: "%04d-%02d-%02d", year, month, day)
}

/// FNV-1a + mulberry32, ported exactly from Flutter `SeededRandom`
/// (app.js dailySeeded). The same day string always yields the same
/// sequence — never use an unseeded random for daily picks.
struct MusicSeededRandom {
    private var state: UInt32

    init(seed: String) {
        var hash: UInt32 = 2166136261
        for unit in seed.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16777619
        }
        state = hash
    }

    mutating func nextDouble() -> Double {
        state = state &+ 0x6D2B79F5
        var x = state
        x = (x ^ (x >> 15)) &* (x | 1)
        x ^= x &+ ((x ^ (x >> 7)) &* (x | 61))
        return Double((x ^ (x >> 14))) / 4294967296
    }

    /// Fisher–Yates with the seeded generator (Flutter dailyShuffle).
    mutating func shuffle<T>(_ input: [T]) -> [T] {
        var array = input
        guard array.count > 1 else { return array }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int(nextDouble() * Double(i + 1))
            array.swapAt(i, j)
        }
        return array
    }
}

/// "m:ss" duration text. Durations are seconds, never milliseconds.
func musicDurationText(seconds: Int) -> String {
    let total = max(0, seconds)
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}
