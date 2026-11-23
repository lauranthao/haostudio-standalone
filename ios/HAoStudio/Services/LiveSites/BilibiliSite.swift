// HAo Studio 2.0 — Bilibili live site (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/bilibili/
// bilibili_site.dart` (room detail + play info only; categories,
// recommend and search are out of this leg's scope).
//
// Room detail: GET `.../xlive/web-room/v1/index/getInfoByRoom`
// (WBI-signed — unsigned calls return code -352).
// Quality+lines: GET `.../xlive/web-room/v2/index/getRoomPlayInfo`
// (quality = g_qn_desc ∩ accept_qn; NEVER invent a quality the
// server didn't confirm; `current_qn` is kept as the applied
// quality — anonymous requests get silently downgraded, e.g.
// 10000 -> 250, verified live 2026-11-16 on room 7734200; the UI
// must reflect the APPLIED quality).
// Lines = url_info[] hosts for the applied qn, ordered
// http_stream/flv first; lines are identified by URL, never by
// index.
//
// Carousel rooms (live_status 2) are NOT resolved here: the
// round-play video needs a start offset the resolution model has
// no field for, so they report offline (the Flutter port starts
// them at 0; the A leg can add carousel support later).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

final class BilibiliLiveSite: LiveSiteResolver {
    var platform: LivePlatform {
        .bilibili
    }

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
    static let referer = "https://live.bilibili.com/"
    static let roomInfoUrl = "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom"
    static let danmuInfoUrl = "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo"
    static let playInfoUrl = "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo"
    static let buvidUrl = "https://api.bilibili.com/x/frontend/finger/spi"

    private let fetcher: LiveDataFetcher
    private let wbiSigner: BilibiliWbiSigner
    private var buvid3: String = ""
    private var buvid4: String = ""
    private var buvidRequestInFlight: Bool = false
    private var buvidCompletions: [(String, String) -> Void] = []

    init(fetcher: LiveDataFetcher? = nil, wbiSigner: BilibiliWbiSigner? = nil) {
        let sharedFetcher = fetcher ?? LiveHTTP.defaultFetcher
        self.fetcher = sharedFetcher
        self.wbiSigner = wbiSigner ?? BilibiliWbiSigner(fetcher: sharedFetcher)
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        BilibiliDanmaku(fetcher: fetcher)
    }

    // MARK: - Room info

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        loadRoomInfo(roomId: trimmed) { result in
            switch result {
            case .success(let room):
                completion(.success(room))
            case .failure:
                // UI path: a transient failure must not blank the
                // card — return the room as offline.
                completion(.success(LiveRoom(roomId: trimmed, platform: .bilibili, isLive: false, link: LivePlatform.bilibili.roomLink(roomId: trimmed))))
            }
        }
    }

    /// Strict room load: throws when no parseable room metadata is
    /// available (recovery callers must see the transient error,
    /// never a disguised "offline").
    func loadRoomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        fetchRoomInfo(roomId: roomId, attempt: 0) { result in
            switch result {
            case .success(let roomInfo):
                self.discoverDanmaku(realRoomId: roomInfo.realRoomId) { danmakuData in
                    completion(.success(BilibiliLiveSite.buildRoom(roomInfo: roomInfo.data, roomId: roomId, realRoomId: roomInfo.realRoomId, danmakuData: danmakuData)))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private struct RoomInfoResult {
        var data: [String: Any]
        var realRoomId: String
    }

    private func fetchRoomInfo(roomId: String, attempt: Int, completion: @escaping (Result<RoomInfoResult, Error>) -> Void) {
        wbiSigner.signUrl("\(BilibiliLiveSite.roomInfoUrl)?room_id=\(roomId)", forceRefresh: attempt > 0) { result in
            switch result {
            case .success(let params):
                guard let url = URL(string: BilibiliLiveSite.roomInfoUrl) else {
                    completion(.failure(LiveError.parseFailed("Bilibili room info url 无效")))
                    return
                }
                let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                self.headers { headers in
                    let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: headers)
                    self.fetcher(request) { data, status, error in
                        if let error = error {
                            self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: error, completion: completion)
                            return
                        }
                        guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data) else {
                            self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: LiveError.emptyResponse, completion: completion)
                            return
                        }
                        do {
                            let parsed = try BilibiliLiveSite.parseRoomInfoResponse(json)
                            let info = LiveJSON.asMap(parsed["room_info"]) ?? [:]
                            let realRoomId = LiveJSON.asString(info["room_id"])
                            completion(.success(RoomInfoResult(data: parsed, realRoomId: realRoomId.isEmpty ? roomId : realRoomId)))
                        } catch {
                            self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: error, completion: completion)
                        }
                    }
                }
            case .failure(let error):
                self.retryOrFailRoomInfo(roomId: roomId, attempt: attempt, error: error, completion: completion)
            }
        }
    }

    private func retryOrFailRoomInfo(roomId: String, attempt: Int, error: Error, completion: @escaping (Result<RoomInfoResult, Error>) -> Void) {
        if attempt == 0 {
            LiveHTTP.after(milliseconds: 180) {
                self.fetchRoomInfo(roomId: roomId, attempt: 1, completion: completion)
            }
        } else {
            completion(.failure(error))
        }
    }

    // MARK: - Danmaku credentials (single quick discovery)

    private func discoverDanmaku(realRoomId: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let roomNumber = Int(realRoomId), roomNumber != 0 else {
            completion(nil)
            return
        }
        headers { headers in
            self.wbiSigner.signUrl("\(BilibiliLiveSite.danmuInfoUrl)?id=\(realRoomId)&type=0") { result in
                switch result {
                case .success(let params):
                    guard let url = URL(string: BilibiliLiveSite.danmuInfoUrl) else {
                        completion(nil)
                        return
                    }
                    let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                    let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: headers)
                    self.fetcher(request) { data, status, _ in
                        guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data) else {
                            completion(nil)
                            return
                        }
                        guard LiveJSON.asInt(json["code"]) == 0, let candidate = LiveJSON.asMap(json["data"]) else {
                            completion(nil)
                            return
                        }
                        let args = BilibiliLiveSite.parseDanmakuArgs(data: candidate, realRoomId: roomNumber, buvid: self.buvid3, cookie: headers["cookie"] ?? "")
                        if args.token.isEmpty {
                            completion(nil)
                            return
                        }
                        completion(args.dictionary)
                    }
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Resolve

    func resolve(roomId: String, quality: LiveQuality?, completion: @escaping (Result<LivePlayUrlResolution, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        loadRoomInfo(roomId: trimmed) { result in
            switch result {
            case .success(let room):
                if !room.isLive {
                    completion(.failure(LiveError.offline))
                    return
                }
                let realRoomId = LiveJSON.asString(room.data?["realRoomId"])
                self.requestPlayInfo(roomId: realRoomId.isEmpty ? trimmed : realRoomId, qualityId: quality?.id) { playResult in
                    switch playResult {
                    case .success(let json):
                        do {
                            let qualities = try BilibiliLiveSite.parsePlayQualities(json)
                            let parsed = try BilibiliLiveSite.parsePlayUrlResolution(json, requestedQualityId: quality?.id)
                            completion(.success(BilibiliLiveSite.mergeResolution(parsed, into: qualities)))
                        } catch {
                            completion(.failure(error))
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Merges the applied quality (with its resolved lines) into
    /// the advertised quality list: the applied tier keeps its
    /// display name from `g_qn_desc` and gains the lines, so the
    /// returned `quality` echoes the tier actually applied and
    /// `appliedUrls` is never empty on success.
    static func mergeResolution(_ parsed: LivePlayUrlResolution, into qualities: [LiveQuality]) -> LivePlayUrlResolution {
        var merged = qualities
        var applied = parsed.quality
        if let appliedQuality = parsed.quality {
            if let index = merged.firstIndex(where: { $0.id == appliedQuality.id }) {
                merged[index].lines = parsed.lines
                applied = merged[index]
            } else {
                merged.append(appliedQuality)
                merged.sort { $0.sort > $1.sort }
            }
        }
        return LivePlayUrlResolution.applying(applied, in: merged)
    }

    private func requestPlayInfo(roomId: String, qualityId: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: BilibiliLiveSite.playInfoUrl) else {
            completion(.failure(LiveError.parseFailed("Bilibili play info url 无效")))
            return
        }
        headers { headers in
            let queryItems = [
                URLQueryItem(name: "room_id", value: roomId),
                URLQueryItem(name: "protocol", value: "0,1"),
                URLQueryItem(name: "format", value: "0,1,2"),
                URLQueryItem(name: "codec", value: "0"),
                URLQueryItem(name: "qn", value: qualityId ?? "0"),
                URLQueryItem(name: "platform", value: "web"),
                URLQueryItem(name: "ptype", value: "8"),
                URLQueryItem(name: "dolby", value: "5"),
                URLQueryItem(name: "panorama", value: "1"),
                URLQueryItem(name: "mask", value: "0"),
                URLQueryItem(name: "no_playurl", value: "0")
            ]
            let request = LiveHTTP.getRequest(url: url, queryItems: queryItems, headers: headers)
            self.fetcher(request) { data, status, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let status = status, (200..<300).contains(status), let data = data, let json = LiveJSON.decodeObject(data) else {
                    completion(.failure(LiveError.emptyResponse))
                    return
                }
                completion(.success(json))
            }
        }
    }

    // MARK: - Headers / buvid

    private func headers(completion: @escaping ([String: String]) -> Void) {
        resolveBuvid { buvid3, buvid4 in
            completion([
                "user-agent": BilibiliLiveSite.userAgent,
                "referer": BilibiliLiveSite.referer,
                "cookie": "buvid3=\(buvid3);buvid4=\(buvid4);"
            ])
        }
    }

    private func resolveBuvid(completion: @escaping (String, String) -> Void) {
        if !buvid3.isEmpty {
            completion(buvid3, buvid4)
            return
        }
        buvidCompletions.append(completion)
        if buvidRequestInFlight {
            return
        }
        buvidRequestInFlight = true
        guard let url = URL(string: BilibiliLiveSite.buvidUrl) else {
            finishBuvidFetch(buvid3: "", buvid4: "")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: LiveHTTP.defaultTimeoutSeconds)
        request.setValue(BilibiliLiveSite.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue(BilibiliLiveSite.referer, forHTTPHeaderField: "referer")
        fetcher(request) { data, _, _ in
            var b3 = ""
            var b4 = ""
            if let data = data, let json = LiveJSON.decodeObject(data), let inner = LiveJSON.asMap(json["data"]) {
                b3 = LiveJSON.asString(inner["b_3"])
                b4 = LiveJSON.asString(inner["b_4"])
            }
            self.finishBuvidFetch(buvid3: b3, buvid4: b4)
        }
    }

    private func finishBuvidFetch(buvid3: String, buvid4: String) {
        self.buvid3 = buvid3
        self.buvid4 = buvid4
        buvidRequestInFlight = false
        let completions = buvidCompletions
        buvidCompletions = []
        for item in completions {
            item(buvid3, buvid4)
        }
    }

    // MARK: - Pure parsers (fixture-testable, no network)

    static func parseRoomInfoResponse(_ json: [String: Any]) throws -> [String: Any] {
        if LiveJSON.asInt(json["code"]) != 0 {
            throw LiveError.apiRejected(code: LiveJSON.asInt(json["code"]), message: LiveJSON.asString(json["message"]))
        }
        guard let data = LiveJSON.asMap(json["data"]) else {
            throw LiveError.parseFailed("Bilibili room metadata is incomplete")
        }
        guard LiveJSON.asMap(data["room_info"]) != nil, LiveJSON.asMap(data["anchor_info"]) != nil else {
            throw LiveError.parseFailed("Bilibili room metadata is incomplete")
        }
        return data
    }

    static func buildRoom(roomInfo: [String: Any], roomId: String, realRoomId: String, danmakuData: [String: Any]?) -> LiveRoom {
        let info = LiveJSON.asMap(roomInfo["room_info"]) ?? [:]
        let anchor = LiveJSON.asMap(roomInfo["anchor_info"]) ?? [:]
        let baseInfo = LiveJSON.asMap(anchor["base_info"]) ?? [:]
        let live = liveStatus(info["live_status"]) == 1
        let face = LiveJSON.asString(baseInfo["face"])
        return LiveRoom(
            roomId: roomId,
            platform: .bilibili,
            title: LiveJSON.asString(info["title"]),
            streamer: LiveJSON.asString(baseInfo["uname"]),
            avatar: face.isEmpty ? "" : "\(face)@100w.jpg",
            cover: LiveJSON.asString(info["cover"]),
            onlineCount: LiveJSON.asInt(info["online"]),
            isLive: live,
            link: LivePlatform.bilibili.roomLink(roomId: roomId),
            data: ["realRoomId": realRoomId],
            danmakuData: danmakuData
        )
    }

    /// 1 = live, 2 = carousel, anything else = offline.
    static func liveStatus(_ value: Any?) -> Int {
        LiveJSON.asInt(value)
    }

    /// token + host_list -> transport args. The generic gateway has
    /// stable public DNS while some resolvers intermittently omit
    /// the regional comet records, so it is tried first and the
    /// regional nodes stay as failovers.
    static func parseDanmakuArgs(data: [String: Any], realRoomId: Int, buvid: String = "", cookie: String = "") -> BilibiliDanmakuArgs {
        let officialFallback = "wss://broadcastlv.chat.bilibili.com/sub"
        var serverUrls: [String] = [officialFallback]
        if let hostList = data["host_list"] as? [Any] {
            for item in hostList {
                guard let hostMap = item as? [String: Any] else {
                    continue
                }
                let host = LiveJSON.asString(hostMap["host"]).trimmingCharacters(in: .whitespaces)
                if host.isEmpty {
                    continue
                }
                let port = Int(LiveJSON.asString(hostMap["wss_port"])) ?? 443
                let endpoint = "wss://\(host)\(port == 443 ? "" : ":\(port)")/sub"
                if !serverUrls.contains(endpoint) {
                    serverUrls.append(endpoint)
                }
            }
        }
        return BilibiliDanmakuArgs(
            roomId: realRoomId,
            token: LiveJSON.asString(data["token"]),
            serverUrls: serverUrls,
            buvid: buvid,
            uid: 0,
            cookie: cookie
        )
    }

    /// Extracts only qualities accepted by at least one returned
    /// codec. The global descriptor list also contains unavailable
    /// tiers and previously produced buttons which could never
    /// resolve to a stream.
    static func parsePlayQualities(_ response: [String: Any]) throws -> [LiveQuality] {
        let playUrl = try playUrlPayload(response)
        var descriptions: [Int: String] = [:]
        if let rawList = playUrl["g_qn_desc"] as? [Any] {
            for raw in rawList {
                guard let item = raw as? [String: Any] else {
                    continue
                }
                guard let qn = Int(LiveJSON.asString(item["qn"])), qn > 0 else {
                    continue
                }
                let description = LiveJSON.asString(item["desc"]).trimmingCharacters(in: .whitespaces)
                descriptions[qn] = description.isEmpty ? "未知清晰度" : description
            }
        }
        var accepted = Set<Int>()
        for payload in codecPayloads(playUrl) {
            if let acceptList = payload.codec["accept_qn"] as? [Any] {
                for rawQn in acceptList {
                    if let qn = Int(LiveJSON.asString(rawQn)), qn > 0 {
                        accepted.insert(qn)
                    }
                }
            }
            if let current = Int(LiveJSON.asString(payload.codec["current_qn"])), current > 0 {
                accepted.insert(current)
            }
        }
        let ordered = accepted.sorted { $0 > $1 }
        return ordered.map { qn in
            LiveQuality(id: String(qn), name: descriptions[qn] ?? "未知清晰度", sort: qn)
        }
    }

    /// Keeps the server-acknowledged `current_qn` with the URLs.
    /// Bilibili can advertise 10000/400 to a guest and still return
    /// qn=250 for every request; the returned `quality` is the
    /// tier actually applied (250), never the requested one — the
    /// caller compares ids and rolls back on a mismatch.
    /// No candidates at all is a failure, not an empty resolution:
    /// a resolution with no URLs must never reach the player.
    static func parsePlayUrlResolution(_ response: [String: Any], requestedQualityId: String?) throws -> LivePlayUrlResolution {
        let playUrl = try playUrlPayload(response)
        let requestedQn = requestedQualityId.flatMap { Int($0) }
        var candidates: [BilibiliStreamCandidate] = []
        for payload in codecPayloads(playUrl) {
            let codec = payload.codec
            guard let currentQn = Int(LiveJSON.asString(codec["current_qn"])), currentQn > 0 else {
                continue
            }
            let baseUrl = LiveJSON.asString(codec["base_url"])
            if baseUrl.isEmpty {
                continue
            }
            if let urlInfoList = codec["url_info"] as? [Any] {
                for rawUrl in urlInfoList {
                    guard let urlMap = rawUrl as? [String: Any] else {
                        continue
                    }
                    let url = "\(LiveJSON.asString(urlMap["host"]))\(baseUrl)\(LiveJSON.asString(urlMap["extra"]))".trimmingCharacters(in: .whitespaces)
                    if !url.hasPrefix("http") {
                        continue
                    }
                    candidates.append(BilibiliStreamCandidate(
                        url: url,
                        currentQn: currentQn,
                        protocolName: payload.protocolName,
                        format: payload.format,
                        codec: LiveJSON.asString(codec["codec_name"])
                    ))
                }
            }
        }
        candidates.sort { a, b in
            let aRequested = a.currentQn == requestedQn ? 1 : 0
            let bRequested = b.currentQn == requestedQn ? 1 : 0
            if aRequested != bRequested {
                return aRequested > bRequested
            }
            let protocolOrder = protocolRank(a.protocolName) - protocolRank(b.protocolName)
            if protocolOrder != 0 {
                return protocolOrder < 0
            }
            let formatOrder = formatRank(a.format) - formatRank(b.format)
            if formatOrder != 0 {
                return formatOrder < 0
            }
            let codecOrder = codecRank(a.codec) - codecRank(b.codec)
            if codecOrder != 0 {
                return codecOrder < 0
            }
            let aMcdn = a.url.contains("mcdn") ? 1 : 0
            let bMcdn = b.url.contains("mcdn") ? 1 : 0
            if aMcdn != bMcdn {
                return aMcdn < bMcdn
            }
            return a.url < b.url
        }
        if candidates.isEmpty {
            throw LiveError.parseFailed("Bilibili 未返回可用流地址")
        }
        let appliedQn = candidates[0].currentQn
        var linesByHost: [(host: String, urls: [String], format: String)] = []
        var seenUrls = Set<String>()
        for candidate in candidates {
            if candidate.currentQn != appliedQn {
                continue
            }
            if !seenUrls.insert(candidate.url).inserted {
                continue
            }
            let host = URL(string: candidate.url)?.host ?? candidate.url
            if let index = linesByHost.firstIndex(where: { $0.host == host }) {
                linesByHost[index].urls.append(candidate.url)
            } else {
                linesByHost.append((host: host, urls: [candidate.url], format: streamFormatOf(candidate.format, url: candidate.url)))
            }
        }
        let lines = linesByHost.map { LiveLine(name: $0.host, urls: $0.urls, format: $0.format) }
        let quality = LiveQuality(id: String(appliedQn), name: String(appliedQn), sort: appliedQn, lines: lines)
        return LivePlayUrlResolution.applying(quality, in: [quality])
    }

    static func streamFormatOf(_ format: String, url: String) -> String {
        let normalized = format.lowercased()
        if normalized == "flv" {
            return "flv"
        }
        if normalized == "hls" || url.lowercased().contains(".m3u8") {
            return "hls"
        }
        return "other"
    }

    static func playUrlPayload(_ response: [String: Any]) throws -> [String: Any] {
        if LiveJSON.asInt(response["code"]) != 0 {
            throw LiveError.apiRejected(code: LiveJSON.asInt(response["code"]), message: LiveJSON.asString(response["message"]))
        }
        guard let data = LiveJSON.asMap(response["data"]) else {
            throw LiveError.parseFailed("Bilibili playurl payload is missing")
        }
        guard let playUrlInfo = LiveJSON.asMap(data["playurl_info"]) else {
            throw LiveError.parseFailed("Bilibili playurl payload is missing")
        }
        guard let playUrl = LiveJSON.asMap(playUrlInfo["playurl"]) else {
            throw LiveError.parseFailed("Bilibili playurl payload is missing")
        }
        return playUrl
    }

    private struct CodecPayload {
        var codec: [String: Any]
        var format: String
        var protocolName: String
    }

    private static func codecPayloads(_ playUrl: [String: Any]) -> [CodecPayload] {
        var payloads: [CodecPayload] = []
        guard let streams = playUrl["stream"] as? [Any] else {
            return payloads
        }
        for rawStream in streams {
            guard let stream = rawStream as? [String: Any] else {
                continue
            }
            let protocolName = LiveJSON.asString(stream["protocol_name"])
            guard let formats = stream["format"] as? [Any] else {
                continue
            }
            for rawFormat in formats {
                guard let format = rawFormat as? [String: Any] else {
                    continue
                }
                let formatName = LiveJSON.asString(format["format_name"])
                guard let codecs = format["codec"] as? [Any] else {
                    continue
                }
                for rawCodec in codecs {
                    guard let codec = rawCodec as? [String: Any] else {
                        continue
                    }
                    payloads.append(CodecPayload(codec: codec, format: formatName, protocolName: protocolName))
                }
            }
        }
        return payloads
    }

    private static func protocolRank(_ value: String) -> Int {
        value == "http_stream" ? 0 : 1
    }

    private static func formatRank(_ value: String) -> Int {
        switch value {
        case "flv":
            return 0
        case "ts":
            return 1
        case "fmp4":
            return 2
        default:
            return 3
        }
    }

    private static func codecRank(_ value: String) -> Int {
        value == "avc" ? 0 : 1
    }
}

private struct BilibiliStreamCandidate {
    var url: String
    var currentQn: Int
    var protocolName: String
    var format: String
    var codec: String
}
