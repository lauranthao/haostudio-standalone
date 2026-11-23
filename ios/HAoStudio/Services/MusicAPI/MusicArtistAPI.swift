// MusicArtistAPI.swift
// Artist search + artist detail.
//
// - Artist search: wy (cloudsearch type=100), tx (derived from
//   song-search results: zhida type 2, otherwise singer-occurrence
//   ranking), kw (r.s ft=artist).
// - Artist detail: wy (albums + songs, paged up to 10 pages, top
//   songs fallback), tx (3 pages of song search filtered to the
//   singer + singer-album endpoint), kw (song search + r.s album +
//   artist endpoints).

import Foundation

final class MusicArtistAPI {
    static let shared = MusicArtistAPI()

    private let client: MusicAPIClient
    private let searchAPI: MusicSearchAPI
    private let albumAPI: MusicAlbumAPI

    init(client: MusicAPIClient = .shared, searchAPI: MusicSearchAPI = .shared,
         albumAPI: MusicAlbumAPI = .shared) {
        self.client = client
        self.searchAPI = searchAPI
        self.albumAPI = albumAPI
    }

    // MARK: - Artist search

    func searchArtists(platform: MusicPlatform, keyword: String, completion: @escaping ([ArtistSummary]) -> Void) {
        switch platform {
        case .wy: searchWyArtists(keyword, completion: completion)
        case .tx: searchTxArtists(keyword, page: 1, completion: completion)
        case .kw: searchKwArtists(keyword, completion: completion)
        default: completion([])
        }
    }

    /// NetEase: cloudsearch type=100.
    func searchWyArtists(_ query: String, completion: @escaping ([ArtistSummary]) -> Void) {
        client.postFormJson(
            "https://music.163.com/api/cloudsearch/pc",
            fields: ["s": query, "type": "100", "limit": "30", "offset": "0"],
            headers: ["User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion([]); return }
            let result = MusicAPIJSON.asMap(json["result"])
            let list = MusicAPIJSON.asList(result?["artists"])
            completion(list.map { x in
                let aliasRaw = (x["alias"] as? [Any]) ?? []
                let alias = aliasRaw.compactMap { element -> String? in
                    if let s = element as? String { return s }
                    if let d = element as? [String: Any] { return MusicAPIJSON.asString(d["name"]) }
                    return nil
                }.first ?? ""
                return ArtistSummary(
                    id: MusicAPIJSON.asString(x["id"]),
                    name: MusicAPIJSON.asString(x["name"]),
                    cover: MusicText.coverHi(
                        MusicAPIJSON.firstString(x, keys: ["picUrl", "img1v1Url"]), platform: "wy"),
                    musicSize: MusicAPIJSON.asInt(x["musicSize"]),
                    albumSize: MusicAPIJSON.asInt(x["albumSize"]),
                    platform: .wy,
                    alias: alias)
            })
        }
    }

    /// QQ artists are DERIVED from search results: zhida when
    /// type == 2, otherwise singer-occurrence ranking.
    func searchTxArtists(_ query: String, page: Int, completion: @escaping ([ArtistSummary]) -> Void) {
        client.getJson(
            "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp",
            query: [
                "g_tk": "5381", "uin": "0", "format": "json",
                "inCharset": "utf-8", "outCharset": "utf-8", "notice": "0",
                "platform": "h5", "needNewCode": "1", "w": query,
                "zhidaqu": "1", "catZhida": "1", "t": "0", "flag": "1",
                "ie": "utf-8", "sem": "1", "aggr": "0",
                "perpage": "30", "n": "30", "p": "\(page)",
                "remoteplace": "txt.mqq.all",
            ],
            headers: ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        ) { json in
            guard let json = json else { completion([]); return }
            completion(MusicArtistAPI.parseTxArtists(json, query: query))
        }
    }

    /// QQ artist payload -> [ArtistSummary]. Pure function.
    static func parseTxArtists(_ json: [String: Any], query: String) -> [ArtistSummary] {
        let data = MusicAPIJSON.asMap(json["data"]) ?? [:]
        var out: [ArtistSummary] = []
        let zhida = MusicAPIJSON.asMap(data["zhida"])
        if let zhida = zhida, MusicAPIJSON.asInt(zhida["type"]) == 2 {
            let mid = MusicAPIJSON.asString(zhida["singermid"])
            out.append(ArtistSummary(
                id: mid,
                name: MusicAPIJSON.asString(zhida["singername"]),
                cover: mid.isEmpty ? "" : MusicText.coverHi(
                    "https://y.gtimg.cn/music/photo_new/T001R300x300M000\(mid).jpg", platform: "tx"),
                musicSize: MusicAPIJSON.asInt(zhida["songnum"]),
                albumSize: MusicAPIJSON.asInt(zhida["albumnum"]),
                platform: .tx))
        }
        var counts: [String: (count: Int, mid: String)] = [:]
        let songData = MusicAPIJSON.asMap(data["song"])
        for song in MusicAPIJSON.asList(songData?["list"]) {
            for singer in MusicAPIJSON.asList(song["singer"]) {
                let name = MusicAPIJSON.asString(singer["name"])
                guard !name.contains(";"), !name.contains("、") else { continue }
                let prev = counts[name]
                counts[name] = (
                    (prev?.count ?? 0) + 1,
                    MusicAPIJSON.asString(singer["mid"]).isEmpty
                        ? (prev?.mid ?? "") : MusicAPIJSON.asString(singer["mid"]))
            }
        }
        let nq = MusicText.normalizeName(query)
        let ranked = counts.filter { entry in
            let n = MusicText.normalizeName(entry.key)
            return n.contains(nq) || nq.contains(n)
        }.sorted { $0.value.count > $1.value.count }
        for entry in ranked {
            guard !out.contains(where: { $0.id == entry.value.mid && !entry.value.mid.isEmpty }) else { continue }
            out.append(ArtistSummary(
                id: entry.value.mid,
                name: entry.key,
                cover: entry.value.mid.isEmpty ? "" : MusicText.coverHi(
                    "https://y.gtimg.cn/music/photo_new/T001R300x300M000\(entry.value.mid).jpg", platform: "tx"),
                musicSize: entry.value.count,
                albumSize: 0,
                platform: .tx))
        }
        return out
    }

    /// Kuwo: r.s ft=artist.
    func searchKwArtists(_ query: String, completion: @escaping ([ArtistSummary]) -> Void) {
        let url = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(query))&ft=artist&rformat=json&encoding=utf8&rn=30&pn=0"
        client.getText(url, headers: ["User-Agent": MusicUA.value]) { text in
            guard let text = text else { completion([]); return }
            let swapped = text.replacingOccurrences(of: "'", with: "\"")
            guard let decoded = MusicJSON.object(from: swapped) as? [String: Any] else {
                completion([])
                return
            }
            completion(MusicAPIJSON.asList(decoded["abslist"]).map { x in
                ArtistSummary(
                    id: MusicAPIJSON.asString(x["ARTISTID"]),
                    name: MusicAPIJSON.asString(x["ARTIST"]),
                    cover: MusicText.coverHi(MusicAPIJSON.asString(x["hts_PICPATH"]), platform: "kw"),
                    musicSize: MusicAPIJSON.asInt(x["SONGNUM"]),
                    albumSize: MusicAPIJSON.asInt(x["ALBUMNUM"]),
                    platform: .kw)
            })
        }
    }

    // MARK: - Artist detail

    func artistDetail(platform: MusicPlatform, id: String, name: String, completion: @escaping (ArtistDetail) -> Void) {
        switch platform {
        case .kw:
            artistDetailKw(name.isEmpty ? id : name, completion: completion)
        case .tx:
            artistDetailTx(id: id, name: name, completion: completion)
        default:
            artistDetailWy(id, completion: completion)
        }
    }

    /// NetEase: albums + songs (paged up to 10 pages of 100), top
    /// songs fallback when the song list is empty.
    func artistDetailWy(_ id: String, completion: @escaping (ArtistDetail) -> Void) {
        let headers = ["User-Agent": MusicUA.value]
        let timeout: TimeInterval = 15
        let group = DispatchGroup()
        var albumsJson: [String: Any]?
        var songsJson: [String: Any]?
        group.enter()
        client.getJson("https://music.163.com/api/artist/albums/\(id)?limit=30&offset=0",
                       headers: headers, timeout: timeout) { json in
            albumsJson = json
            group.leave()
        }
        group.enter()
        client.getJson("https://music.163.com/api/v1/artist/songs?id=\(id)&limit=100&offset=0",
                       headers: headers, timeout: timeout) { json in
            songsJson = json
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            var allSongs = MusicAPIJSON.asList(songsJson?["songs"])
            let total = MusicAPIJSON.asInt(songsJson?["total"])
            let pages = min(max(Int(ceil(Double(total) / 100.0)), 0), 10)
            let finish: ([[String: Any]]) -> Void = { extraSongs in
                allSongs.append(contentsOf: extraSongs)
                if allSongs.isEmpty {
                    // Top-songs fallback.
                    self.client.getJson(
                        "https://music.163.com/api/artist/top/song?id=\(id)&limit=100",
                        headers: headers, timeout: timeout) { topJson in
                        let topSongs = MusicAPIJSON.asList(topJson?["songs"])
                        completion(self.buildWyArtistDetail(
                            albumsJson: albumsJson ?? [:], songs: topSongs.isEmpty ? allSongs : topSongs))
                    }
                    return
                }
                completion(self.buildWyArtistDetail(albumsJson: albumsJson ?? [:], songs: allSongs))
            }
            if pages > 1 {
                let pageGroup = DispatchGroup()
                var extra: [[String: Any]] = []
                let lock = NSLock()
                for page in 1..<pages {
                    pageGroup.enter()
                    self.client.getJson(
                        "https://music.163.com/api/v1/artist/songs?id=\(id)&limit=100&offset=\(page * 100)",
                        headers: headers, timeout: timeout) { json in
                        lock.lock()
                        extra.append(contentsOf: MusicAPIJSON.asList(json?["songs"]))
                        lock.unlock()
                        pageGroup.leave()
                    }
                }
                pageGroup.notify(queue: .main) { finish(extra) }
            } else {
                finish([])
            }
        }
    }

    private func buildWyArtistDetail(albumsJson: [String: Any], songs: [[String: Any]]) -> ArtistDetail {
        let albums = MusicAPIJSON.asList(albumsJson["hotAlbums"]).map { a in
            AlbumSummary(
                id: MusicAPIJSON.asString(a["id"]),
                name: MusicAPIJSON.asString(a["name"]),
                cover: MusicText.coverHi(MusicAPIJSON.asString(a["picUrl"]), platform: "wy"),
                artist: MusicAPIJSON.asString(MusicAPIJSON.asMap(a["artist"])?["name"]),
                publishTime: MusicAPIJSON.asInt(a["publishTime"]),
                songCount: MusicAPIJSON.asInt(a["size"]),
                platform: .wy)
        }
        let artist = MusicAPIJSON.asMap(albumsJson["artist"]) ?? [:]
        let tracks = songs.map { s in
            var artists = MusicAPIJSON.asList(s["artists"])
            if artists.isEmpty { artists = MusicAPIJSON.asList(s["ar"]) }
            let album = MusicAPIJSON.asMap(s["album"]) ?? MusicAPIJSON.asMap(s["al"]) ?? [:]
            let durMs = MusicAPIJSON.asInt(s["duration"] != nil ? s["duration"] : s["dt"])
            return MusicTrack(
                id: MusicAPIJSON.asString(s["id"]),
                title: MusicAPIJSON.asString(s["name"]),
                artist: artists.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: " / "),
                album: MusicAPIJSON.asString(album["name"]),
                coverURL: URL(string: MusicText.coverHi(MusicAPIJSON.asString(album["picUrl"]), platform: "wy")),
                duration: (Double(durMs) / 1000.0).rounded(),
                sourceID: "wy")
        }
        return ArtistDetail(
            name: MusicAPIJSON.asString(artist["name"]),
            pic: MusicText.coverHi(MusicAPIJSON.asString(artist["picUrl"]), platform: "wy"),
            musicSize: MusicAPIJSON.asInt(artist["musicSize"]),
            albumSize: MusicAPIJSON.asInt(artist["albumSize"]),
            songs: tracks,
            albums: albums)
    }

    /// QQ: 3 pages of song search filtered to the singer + the
    /// singer-album endpoint.
    func artistDetailTx(id mid: String, name: String, completion: @escaping (ArtistDetail) -> Void) {
        let query = (name.isEmpty ? mid : name).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            completion(ArtistDetail(name: ""))
            return
        }
        let headers = ["Referer": "https://y.qq.com/", "User-Agent": MusicUA.value]
        let timeout: TimeInterval = 15
        let group = DispatchGroup()
        var pageResults: [[String: Any]?] = [nil, nil, nil]
        for page in 1...3 {
            group.enter()
            client.getJson(
                "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp",
                query: [
                    "g_tk": "5381", "uin": "0", "format": "json",
                    "inCharset": "utf-8", "outCharset": "utf-8", "notice": "0",
                    "platform": "h5", "needNewCode": "1", "w": query,
                    "zhidaqu": "1", "catZhida": "1", "t": "0", "flag": "1",
                    "ie": "utf-8", "sem": "1", "aggr": "0",
                    "perpage": "30", "n": "30", "p": "\(page)",
                    "remoteplace": "txt.mqq.all",
                ],
                headers: headers, timeout: timeout
            ) { json in
                pageResults[page - 1] = json
                group.leave()
            }
        }
        var albumsJson: [String: Any]?
        group.enter()
        if mid.isEmpty {
            albumsJson = [:]
            group.leave()
        } else {
            client.getJson(
                "https://c.y.qq.com/v8/fcg-bin/fcg_v8_singer_album.fcg",
                query: [
                    "singermid": mid, "order": "time", "begin": "0", "num": "30",
                    "g_tk": "5381", "loginUin": "0", "hostUin": "0",
                    "format": "json", "inCharset": "utf8", "outCharset": "utf-8",
                    "notice": "0", "platform": "yqq.json", "needNewCode": "0",
                ],
                headers: headers, timeout: timeout
            ) { json in
                albumsJson = json
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let albumsData = MusicAPIJSON.asMap(albumsJson?["data"]) ?? [:]
            let albums = MusicAPIJSON.asList(albumsData["list"]).compactMap { a -> AlbumSummary? in
                let albumMid = MusicAPIJSON.asString(a["albumMID"])
                let pubTime = MusicAPIJSON.asString(a["pubTime"])
                let publishMs: Int
                if let date = ISO8601DateFormatter().date(from: pubTime) {
                    publishMs = Int(date.timeIntervalSince1970 * 1000)
                } else {
                    publishMs = 0
                }
                let summary = AlbumSummary(
                    id: albumMid,
                    name: MusicAPIJSON.asString(a["albumName"]),
                    cover: albumMid.isEmpty ? "" : MusicText.coverHi(
                        "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg", platform: "tx"),
                    artist: MusicAPIJSON.asString(a["singerName"]).isEmpty
                        ? query : MusicAPIJSON.asString(a["singerName"]),
                    publishTime: publishMs,
                    songCount: MusicAPIJSON.asInt(MusicAPIJSON.asMap(a["latest_song"])?["song_count"]),
                    platform: .tx)
                guard !summary.id.isEmpty, !summary.name.isEmpty else { return nil }
                return summary
            }
            var seen = Set<String>()
            var songs: [MusicTrack] = []
            var songnum = 0
            var albumnum = 0
            for pageJson in pageResults {
                let data = MusicAPIJSON.asMap(pageJson?["data"]) ?? [:]
                let zhida = MusicAPIJSON.asMap(data["zhida"])
                if let zhida = zhida, MusicAPIJSON.asInt(zhida["type"]) == 2,
                   (mid.isEmpty || MusicAPIJSON.asString(zhida["singermid"]) == mid) {
                    songnum = MusicAPIJSON.asInt(zhida["songnum"])
                    albumnum = MusicAPIJSON.asInt(zhida["albumnum"])
                }
                let songData = MusicAPIJSON.asMap(data["song"])
                for s in MusicAPIJSON.asList(songData?["list"]) {
                    let songmid = MusicAPIJSON.asString(s["songmid"])
                    guard !songmid.isEmpty, !seen.contains(songmid) else { continue }
                    let singers = MusicAPIJSON.asList(s["singer"])
                    let mine = mid.isEmpty
                        ? singers.contains { MusicAPIJSON.asString($0["name"]) == query }
                        : singers.contains { MusicAPIJSON.asString($0["mid"]) == mid }
                    guard mine else { continue }
                    seen.insert(songmid)
                    let albummid = MusicAPIJSON.asString(s["albummid"])
                    songs.append(MusicTrack(
                        id: songmid,
                        title: MusicAPIJSON.asString(s["songname"]),
                        artist: singers.map { MusicAPIJSON.asString($0["name"]) }.joined(separator: " / "),
                        album: MusicAPIJSON.asString(s["albumname"]),
                        coverURL: URL(string: albummid.isEmpty ? "" : MusicText.coverHi(
                            "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albummid).jpg", platform: "tx")),
                        duration: TimeInterval(MusicAPIJSON.asInt(s["interval"])),
                        sourceID: "tx"))
                }
            }
            completion(ArtistDetail(
                name: query,
                pic: mid.isEmpty ? "" : MusicText.coverHi(
                    "https://y.gtimg.cn/music/photo_new/T001R300x300M000\(mid).jpg", platform: "tx"),
                musicSize: songnum > 0 ? songnum : songs.count,
                albumSize: !albums.isEmpty ? albums.count : albumnum,
                songs: songs,
                albums: albums))
        }
    }

    /// Kuwo: song search + r.s album + artist endpoints in parallel.
    func artistDetailKw(_ name: String, completion: @escaping (ArtistDetail) -> Void) {
        let group = DispatchGroup()
        var songs: [MusicTrack] = []
        var albumsText: String?
        var artistText: String?
        group.enter()
        searchAPI.searchKw(name, limit: 100) { list in
            songs = list
            group.leave()
        }
        group.enter()
        let albumsURL = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(name))&ft=album&rformat=json&encoding=utf8&rn=30&pn=0"
        client.getText(albumsURL, headers: ["User-Agent": MusicUA.value]) { text in
            albumsText = text
            group.leave()
        }
        group.enter()
        let artistURL = "https://search.kuwo.cn/r.s?all=\(MusicAPIClient.percentEncode(name))&ft=artist&rformat=json&encoding=utf8&rn=3&pn=0"
        client.getText(artistURL, headers: ["User-Agent": MusicUA.value]) { text in
            artistText = text
            group.leave()
        }
        group.notify(queue: .main) {
            let albums = albumsText.map { MusicAlbumAPI.parseKwAlbums($0) } ?? []
            var pic = ""
            if let text = artistText {
                let swapped = text.replacingOccurrences(of: "'", with: "\"")
                if let decoded = MusicJSON.object(from: swapped) as? [String: Any] {
                    let list = MusicAPIJSON.asList(decoded["abslist"])
                    func norm(_ s: String) -> String {
                        s.components(separatedBy: .whitespaces).joined()
                    }
                    let hit = list.first { norm(MusicAPIJSON.asString($0["ARTIST"])) == norm(name) }
                        ?? list.first ?? [:]
                    if !hit.isEmpty {
                        let base = MusicAPIJSON.asString(decoded["BASEPICPATH"])
                        let picPath = MusicAPIJSON.asString(hit["ARTISTPIC"]).isEmpty
                            ? base + MusicAPIJSON.asString(hit["PICPATH"])
                            : MusicAPIJSON.asString(hit["ARTISTPIC"])
                        pic = MusicText.coverHi(picPath, platform: "kw")
                    }
                }
            }
            completion(ArtistDetail(
                name: name, pic: pic, musicSize: songs.count, albumSize: albums.count,
                songs: songs, albums: albums))
        }
    }
}
