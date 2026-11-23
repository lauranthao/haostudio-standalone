// MusicAlbumAPI.swift
// Album search + album detail.
//
// - Album search: wy (cloudsearch type=10), tx (client_search t=8),
//   kg (aggregates official song-search results by album — Kugou has
//   no dedicated album endpoint), kw (r.s ft=album).
// - Album detail: wy (`/api/v1/album/<id>`), tx
//   (`fcg_v8_album_info_cp.fcg`), kw (search the album name and
//   filter to the artist — no public album-track endpoint).

import Foundation

final class MusicAlbumAPI {
    static let shared = MusicAlbumAPI()

    private let client: MusicAPIClient
    private let searchAPI: MusicSearchAPI

    init(client: MusicAPIClient = .shared, searchAPI: MusicSearchAPI = .shared) {
        self.client = client
        self.searchAPI = searchAPI
    }

    // MARK: - Album search

    func searchAlbums(platform: MusicPlatform, keyword: String, completion: @escaping ([AlbumSummary]) -> Void) {
        switch platform {
        case .wy: searchWyAlbums(keyword, completion: completion)
        case .tx: searchTxAlbums(keyword, completion: completion)
        case .kg: searchKgAlbums(keyword, completion: completion)
        case .kw: searchKwAlbums(keyword, completion: completion)
        case .mg: completion([])
        }
    }

    /// NetEase album search: POST /api/cloudsearch/pc, type=10,
    /// `result.albums[]`: id / name / artist.name / picUrl /
    /// publishTime (ms) / size.
    func searchWyAlbums(_ query: String, completion: @escaping ([AlbumSummary]) -> Void) {
        client.getJson(
            "https://music.163.com/api/cloudsearch/pc",
            query: ["s": query, "type": "10", "limit": "30", "offset": "0"],
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion([]); return }
            let result = MusicAPIJSON.asMap(json["result"]) ?? [:]
            completion(MusicAlbumAPI.parseWyAlbums(result))
        }
    }

    /// NetEase album payload -> [AlbumSummary] (`result.albums`).
    /// Pure function (unit-tested on canned JSON).
    static func parseWyAlbums(_ result: [String: Any]) -> [AlbumSummary] {
        MusicAPIJSON.asList(result["albums"]).compactMap { x in
            let summary = AlbumSummary(
                id: MusicAPIJSON.asString(x["id"]),
                name: MusicAPIJSON.asString(x["name"]),
                cover: MusicText.coverHi(MusicAPIJSON.asString(x["picUrl"]), platform: "wy"),
                artist: MusicAPIJSON.asString(MusicAPIJSON.asMap(x["artist"])?["name"]),
                publishTime: MusicAPIJSON.asInt(x["publishTime"]),
                songCount: MusicAPIJSON.asInt(x["size"]),
                platform: .wy)
            guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
            return summary
        }
    }

    /// QQ album search: client_search_cp t=8, `data.album.list`.
    /// No musicu fallback (there is no musicu helper in this
    /// codebase): an empty first leg returns [].
    func searchTxAlbums(_ query: String, completion: @escaping ([AlbumSummary]) -> Void) {
        client.getJson(
            "https://c.y.qq.com/soso/fcgi-bin/client_search_cp",
            query: [
                "g_tk": "5381", "uin": "0", "format": "json",
                "inCharset": "utf-8", "outCharset": "utf-8", "notice": "0",
                "platform": "h5", "needNewCode": "1", "w": query,
                "zhidaqu": "1", "catZhida": "1", "t": "8", "flag": "1",
                "ie": "utf-8", "sem": "1", "aggr": "0",
                "perpage": "30", "n": "30", "p": "1",
                "remoteplace": "txt.mqq.all",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion([]); return }
            let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
            completion(MusicAlbumAPI.parseTxAlbums(data))
        }
    }

    /// QQ album payload -> [AlbumSummary] (`data.album.list`). Name
    /// from name/albumname/albumName, mid from mid/albummid/albumMID,
    /// artist from singer[].name (fallback singerName), cover from
    /// the T002R300x300M000{mid} photo URL, trackCount from total.
    /// An item with no mid gets the opaque id `qq-album-{id}-{name}`
    /// — the album detail page treats that id as "no real id" and
    /// falls back to a name search.
    static func parseTxAlbums(_ data: [String: Any]) -> [AlbumSummary] {
        let album = MusicAPIJSON.asMap(data["album"])
        let list = album == nil ? [] : MusicAPIJSON.asList(album?["list"])
        return list.compactMap { x in
            let name = MusicAPIJSON.firstString(x, keys: ["name", "albumname", "albumName"])
            let mid = MusicAPIJSON.firstString(x, keys: ["mid", "albummid", "albumMID"])
            let singers = MusicAPIJSON.asList(x["singer"])
            var artist = singers.map { MusicAPIJSON.asString($0["name"]) }
                .filter { !$0.isEmpty }.joined(separator: " / ")
            if artist.isEmpty { artist = MusicAPIJSON.asString(x["singerName"]) }
            let numericId = MusicAPIJSON.asInt(x["id"])
            let summary = AlbumSummary(
                id: mid.isEmpty ? "qq-album-\(numericId)-\(name)" : mid,
                name: name,
                cover: mid.isEmpty ? "" : MusicText.coverHi(
                    "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg", platform: "tx"),
                artist: artist,
                songCount: MusicAPIJSON.asInt(x["total"]),
                platform: .tx)
            guard !summary.name.isEmpty else { return nil }
            return summary
        }
    }

    /// Kugou album search: aggregates official song-search results
    /// by album. The id is the opaque `album|artist` key — the album
    /// detail page treats it as "no real id" and falls back to a
    /// name search. Kugou songs carry no cover in our search, so
    /// cover is ''.
    func searchKgAlbums(_ query: String, completion: @escaping ([AlbumSummary]) -> Void) {
        searchAPI.searchKg(query, limit: 40) { songs in
            completion(MusicAlbumAPI.parseKgAlbums(songs))
        }
    }

    /// Kugou song results -> deduped [AlbumSummary] list.
    static func parseKgAlbums(_ songs: [MusicTrack]) -> [AlbumSummary] {
        var seen = Set<String>()
        var out: [AlbumSummary] = []
        for song in songs {
            guard !song.album.isEmpty else { continue }
            let key = "\(song.album)|\(song.artist)"
            guard seen.insert(key).inserted else { continue }
            out.append(AlbumSummary(id: key, name: song.album, artist: song.artist, platform: .kg))
        }
        return out
    }

    /// Kuwo album search (r.s ft=album).
    func searchKwAlbums(_ query: String, completion: @escaping ([AlbumSummary]) -> Void) {
        let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(query))&ft=album&rformat=json&encoding=utf8&rn=30&pn=0"
        client.getText(url, headers: ["User-Agent": MusicUA.value]) { text in
            guard let text = text else { completion([]); return }
            completion(MusicAlbumAPI.parseKwAlbums(text))
        }
    }

    /// Kuwo r.s ft=album payload -> [AlbumSummary]. Same field
    /// mapping as `artistDetailKw`'s album parse: id from
    /// ALBUMID/DC_TARGETID/albumid/id, name from ALBUM/name, artist
    /// from ARTIST/artist, cover from hts_PICPATH/PICPATH, track count
    /// from SONGNUM.
    static func parseKwAlbums(_ text: String) -> [AlbumSummary] {
        let swapped = text.replacingOccurrences(of: "'", with: "\"")
        guard let decoded = MusicJSON.object(from: swapped) as? [String: Any] else { return [] }
        var raw = MusicAPIJSON.asList(decoded["abslist"])
        if raw.isEmpty { raw = MusicAPIJSON.asList(decoded["albumlist"]) }
        return raw.compactMap { a in
            let summary = AlbumSummary(
                id: MusicAPIJSON.firstString(a, keys: ["ALBUMID", "DC_TARGETID", "albumid", "id"]),
                name: MusicText.decodeEntities(MusicAPIJSON.firstString(a, keys: ["ALBUM", "name"])),
                cover: MusicText.coverHi(
                    MusicAPIJSON.firstString(a, keys: ["hts_PICPATH", "PICPATH"]), platform: "kw"),
                artist: MusicText.decodeEntities(MusicAPIJSON.firstString(a, keys: ["ARTIST", "artist"])),
                songCount: MusicAPIJSON.asInt(a["SONGNUM"]),
                platform: .kw)
            guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
            return summary
        }
    }

    // MARK: - Album detail

    func albumSongs(id: String, platform: MusicPlatform, name: String, artist: String, completion: @escaping (AlbumDetail) -> Void) {
        switch platform {
        case .tx:
            albumSongsTx(id, completion: completion)
        case .kw:
            albumSongsKw(id: id, name: name, artist: artist, completion: completion)
        default:
            albumSongsWy(id, completion: completion)
        }
    }

    /// NetEase: `/api/v1/album/<id>`.
    func albumSongsWy(_ id: String, completion: @escaping (AlbumDetail) -> Void) {
        client.getJson(
            "https://music.163.com/api/v1/album/\(id)",
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else {
                completion(AlbumDetail(name: ""))
                return
            }
            let songs = MusicAPIJSON.asList(json["songs"])
            let firstAlbum = songs.isEmpty ? [:] : (MusicAPIJSON.asMap(songs[0]["al"]) ?? [:])
            let detail = AlbumDetail(
                name: MusicAPIJSON.asString(firstAlbum["name"]),
                pic: MusicText.coverHi(MusicAPIJSON.asString(firstAlbum["picUrl"]), platform: "wy"),
                artist: MusicAPIJSON.asString(MusicAPIJSON.asMap(firstAlbum["artist"])?["name"]),
                songs: songs.map { s in
                    let artists = MusicAPIJSON.asList(s["ar"])
                    let album = MusicAPIJSON.asMap(s["al"])
                    let durMs = MusicAPIJSON.asInt(s["duration"] != nil ? s["duration"] : s["dt"])
                    return MusicTrack(
                        id: MusicAPIJSON.asString(s["id"]),
                        title: MusicAPIJSON.asString(s["name"]),
                        artist: artists.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: " / "),
                        album: MusicAPIJSON.asString(album?["name"]),
                        coverURL: URL(string: MusicText.coverHi(MusicAPIJSON.asString(album?["picUrl"]), platform: "wy")),
                        duration: (Double(durMs) / 1000.0).rounded(),
                        sourceID: "wy")
                })
            completion(detail)
        }
    }

    /// QQ: `fcg_v8_album_info_cp.fcg`.
    func albumSongsTx(_ albummid: String, completion: @escaping (AlbumDetail) -> Void) {
        client.getJson(
            "https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg",
            query: [
                "albummid": albummid, "g_tk": "5381", "loginUin": "0",
                "hostUin": "0", "format": "json", "inCharset": "utf8",
                "outCharset": "utf-8", "notice": "0", "platform": "yqq.json",
                "needNewCode": "0",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else {
                completion(AlbumDetail(name: ""))
                return
            }
            let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
            let pic = albummid.isEmpty ? "" : MusicText.coverHi(
                "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albummid).jpg", platform: "tx")
            let detail = AlbumDetail(
                name: MusicAPIJSON.asString(data["name"]),
                pic: pic,
                artist: MusicAPIJSON.asString(data["singername"]),
                songs: MusicAPIJSON.asList(data["list"]).compactMap { s in
                    let singers = MusicAPIJSON.asList(s["singer"])
                    let track = MusicTrack(
                        id: MusicAPIJSON.asString(s["songmid"]),
                        title: MusicAPIJSON.asString(s["songname"]),
                        artist: singers.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: " / "),
                        coverURL: URL(string: pic),
                        duration: TimeInterval(MusicAPIJSON.asInt(s["interval"])),
                        sourceID: "tx")
                    guard !track.id.isEmpty, !track.title.isEmpty else { return nil }
                    return track
                })
            completion(detail)
        }
    }

    /// Kuwo has no public album-track endpoint — search the album
    /// name and filter to the artist (intentional workaround).
    func albumSongsKw(id: String, name: String, artist: String, completion: @escaping (AlbumDetail) -> Void) {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            completion(AlbumDetail(name: "", artist: artist))
            return
        }
        searchAPI.searchKw(query, limit: 100) { list in
            var filtered = list
            let target = MusicText.normalizeName(artist)
            if !target.isEmpty {
                let mine = list.filter { track in
                    let first = MusicText.normalizeName(MusicAPIJSON.firstArtist(track.artist))
                    return first == target || MusicText.normalizeName(track.artist).contains(target)
                }
                if !mine.isEmpty { filtered = mine }
            }
            completion(AlbumDetail(name: query, artist: artist, songs: filtered))
        }
    }
}
