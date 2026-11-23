// HAo Studio 2.0 — Kuaishou live site (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/kuaishou/
// kuaishou_site.dart` (room detail, qualities, resolve) +
// `kuaishou_room_parser.dart` (initial-state scrape, quality
// parsing) + `kuaishou_models.dart` (play descriptors).
//
// Room detail: HTML scrape — GET `https://live.kuaishou.com/u/
// <roomId>`, `window.__INITIAL_STATE__` -> `liveroom.playList[0]`
// (fallback: legacy top-level `room` object). Balanced-brace
// extraction (string-aware), so a `;` or `</script>` inside a JSON
// string value cannot truncate the state the way a non-greedy
// regex can; the upstream regex is kept as a fallback.
//
// ROOMID RULE: the room identifier is `author.id`, NEVER
// `liveStream.id`. The live-stream id is only the danmaku/feed
// credential (`danmakuData['liveStreamId']`) and the `link` value
// for the native kwai:// deep link.
//
// Qualities: `playUrls` descriptors, each with
// `adaptationSet.representation[]` (one entry per quality, each
// with a signed URL). `{h264|avc}` descriptors first, then
// `{hevc|h265}`; same name+sort merged across CDNs into one
// quality -> N lines. No re-signing: the URLs arrive signed.
// Kuaishou URLs carry no wsTime-style lease, so refreshAt /
// invalidAt stay nil; the signed URLs expire on the server's own
// txTime.
//
// Scope: room parse + room info + resolve only. Search, lists and
// categories are not this leg's work and are not ported.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Stream format / labels (pure)

extension KuaishouLiveSite {
    /// Declared stream format for one Kuaishou play URL, from its
    /// path suffix (the server signs the transport into the URL
    /// itself — no re-signing, no format field on the
    /// representation). Unknown suffixes report `other` so the
    /// player probes instead of assuming.
    static func kuaishouStreamFormat(_ url: String) -> String {
        let path = url.components(separatedBy: "?")[0].lowercased()
        if path.hasSuffix(".m3u8") {
            return "hls"
        }
        if path.hasSuffix(".flv") {
            return "flv"
        }
        return "other"
    }

    /// Normalise a Kuaishou quality label for display, without
    /// changing the opaque id used to request that stream. CJK
    /// labels (what Kuaishou actually serves: 高清 / 超清 / 蓝光 4M /
    /// 蓝光 质臻) pass through untouched; bare SDK tokens map onto
    /// the same vocabulary.
    static func normalizeKuaishouQualityLabel(_ rawLabel: String) -> String {
        let raw = rawLabel.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if containsCJK(raw) {
            return raw
        }
        let token = raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        switch token {
        case "original", "origin", "origion", "source":
            return "原画"
        case "blue", "bluray", "blueray":
            return "蓝光"
        case "uhd", "super", "superhd", "fullhd", "fhd":
            return "超清"
        case "hd", "high":
            return "高清"
        case "sd", "standard", "medium":
            return "标清"
        case "low", "ld", "smooth", "fluent":
            return "流畅"
        case "auto":
            return "自动"
        case "default":
            return "默认"
        default:
            return raw.isEmpty ? "默认" : raw
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "[\\u{3400}-\\u{9fff}]", options: []) else {
            return false
        }
        return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - Room parser (pure, fixture-testable)

extension KuaishouLiveSite {
    /// Parse `window.__INITIAL_STATE__` out of a room-page HTML
    /// document. Throws when no parseable state is found.
    static func extractKuaishouInitialState(html: String) throws -> [String: Any] {
        let marker = "window.__INITIAL_STATE__"
        if let markerRange = html.range(of: marker),
           let braceStart = html[markerRange.upperBound...].firstIndex(of: "\u{7B}"),
           let end = matchingBraceEnd(html, start: braceStart),
           let decoded = decodeStateJson(String(html[braceStart..<end])) {
            return decoded
        }
        let pattern = "window\\.__INITIAL_STATE__\\s*=\\s*(.*?);\\s*</script>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges >= 2,
           let captureRange = Range(match.range(at: 1), in: html),
           let decoded = decodeStateJson(String(html[captureRange])) {
            return decoded
        }
        throw LiveError.parseFailed("快手初始状态缺失")
    }

    private static func decodeStateJson(_ text: String) -> [String: Any]? {
        // The state embeds bare `undefined` values; JSON needs `null`.
        let replaced = text.replacingOccurrences(of: "undefined", with: "null")
        guard let data = replaced.data(using: .utf8) else {
            return nil
        }
        return LiveJSON.decodeObject(data)
    }

    /// Index just past the `}` matching the `{` at `start`, or nil
    /// when the braces never balance (or a string never terminates).
    static func matchingBraceEnd(_ text: String, start: String.Index) -> String.Index? {
        let chars = Array(text[start...])
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, ch) in chars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return text.index(start, offsetBy: offset + 1)
                }
            }
        }
        return nil
    }

    /// Parse a Kuaishou room page into a `LiveRoom`.
    ///
    /// Reads `liveroom.playList[0]` (current shape), falling back to
    /// a top-level `room` object (older shape). The room id is
    /// `author.id`; the live-stream id goes to
    /// `danmakuData['liveStreamId']` and `link` only. An offline room
    /// (empty `liveStream`, `isLiving: false`, or an `errorType`
    /// card such as the rate-limit "请求过快，请稍后重试") parses as
    /// `isLive: false` with whatever author info the page carried —
    /// never throws for a reachable page. Throws when the page
    /// carries no room metadata at all.
    static func parseKuaishouRoomPage(html: String, roomId: String) throws -> LiveRoom {
        let state = try extractKuaishouInitialState(html: html)
        var room: [String: Any]?
        if let liveRoom = LiveJSON.asMap(state["liveroom"]),
           let playList = liveRoom["playList"] as? [Any], !playList.isEmpty,
           let first = LiveJSON.asMap(playList[0]) {
            room = first
        }
        if room == nil {
            room = LiveJSON.asMap(state["room"])
        }
        guard let room = room else {
            throw LiveError.parseFailed("快手房间元数据缺失")
        }
        let liveStream = LiveJSON.asMap(room["liveStream"]) ?? [:]
        let author = LiveJSON.asMap(room["author"]) ?? [:]
        let gameInfo = LiveJSON.asMap(room["gameInfo"]) ?? [:]
        let rawLiveState = room["isLiving"]
        let live = (rawLiveState as? Bool) == true
            || (LiveJSON.asIntOrNil(rawLiveState) ?? 0) == 1
            || LiveJSON.asString(rawLiveState).lowercased() == "true"
        let description = LiveJSON.asString(author["description"])
        let liveStreamId = LiveJSON.asString(liveStream["id"])
        let poster = LiveJSON.asString(liveStream["poster"])
        let playUrls = liveStream["playUrls"]
        return LiveRoom(
            roomId: LiveJSON.asString(author["id"]).isEmpty ? roomId : LiveJSON.asString(author["id"]),
            platform: .kuaishou,
            title: description.replacingOccurrences(of: "\n", with: " "),
            streamer: LiveJSON.asString(author["name"]),
            avatar: LiveJSON.asString(author["avatar"]),
            cover: posterUrl(poster),
            onlineCount: live ? (LiveJSON.asIntOrNil(gameInfo["watchingCount"]) ?? 0) : 0,
            isLive: live,
            link: liveStreamId,
            data: playUrls == nil ? nil : ["playUrls": playUrls!],
            danmakuData: liveStreamId.isEmpty ? nil : ["liveStreamId": liveStreamId]
        )
    }

    /// Parse Kuaishou `playUrls` descriptors into qualities.
    ///
    /// Both current room-page and recommendation payloads are
    /// handled: room pages expose `{h264: ..., hevc: ...}` while
    /// list/replay entries are usually a direct adaptation-set
    /// descriptor. Multiple descriptors can represent CDN lines, so
    /// URLs of the same quality are merged and deduped into one
    /// quality -> N lines. An empty result means the room is
    /// unplayable — callers return it as-is, never invent a quality.
    static func parseKuaishouPlayQualities(_ raw: Any?) -> [LiveQuality] {
        let descriptors: [Any]
        if let list = raw as? [Any] {
            descriptors = list
        } else if raw != nil {
            descriptors = [raw!]
        } else {
            descriptors = []
        }
        struct MergedQuality {
            var name: String
            var sort: Int
            var codecRank: Int
            var urls: [String]
        }
        var merged: [String: MergedQuality] = [:]
        for rawDescriptor in descriptors {
            guard let descriptor = rawDescriptor as? [String: Any] else {
                continue
            }
            struct CodecSet {
                var suffix: String
                var codecRank: Int
                var codec: String?
                var descriptor: [String: Any]
            }
            var sets: [CodecSet] = []
            for codec in ["h264", "avc"] {
                if let candidate = LiveJSON.asMap(descriptor[codec]), !representationsOf(candidate).isEmpty {
                    sets.append(CodecSet(suffix: "", codecRank: 0, codec: "avc", descriptor: candidate))
                    break
                }
            }
            for codec in ["hevc", "h265"] {
                if let candidate = LiveJSON.asMap(descriptor[codec]), !representationsOf(candidate).isEmpty {
                    sets.append(CodecSet(suffix: " · H.265", codecRank: 1, codec: "hevc", descriptor: candidate))
                    break
                }
            }
            if sets.isEmpty {
                sets.append(CodecSet(suffix: "", codecRank: 0, codec: nil, descriptor: descriptor))
            }
            for set in sets {
                for item in representationsOf(set.descriptor) {
                    guard let item = item as? [String: Any] else {
                        continue
                    }
                    let url = LiveJSON.asString(item["url"]).trimmingCharacters(in: .whitespaces)
                    guard let uri = URL(string: url), let scheme = uri.scheme, (scheme == "http" || scheme == "https") else {
                        continue
                    }
                    let sort = LiveJSON.asIntOrNil(item["level"]) ?? LiveJSON.asIntOrNil(item["bitrate"]) ?? 0
                    let rawName: String
                    if !LiveJSON.asString(item["name"]).trimmingCharacters(in: .whitespaces).isEmpty {
                        rawName = LiveJSON.asString(item["name"]).trimmingCharacters(in: .whitespaces)
                    } else if !LiveJSON.asString(item["shortName"]).trimmingCharacters(in: .whitespaces).isEmpty {
                        rawName = LiveJSON.asString(item["shortName"]).trimmingCharacters(in: .whitespaces)
                    } else if !LiveJSON.asString(item["qualityType"]).trimmingCharacters(in: .whitespaces).isEmpty {
                        rawName = LiveJSON.asString(item["qualityType"]).trimmingCharacters(in: .whitespaces)
                    } else {
                        rawName = "清晰度 \(sort)"
                    }
                    let name = set.suffix.isEmpty ? rawName : "\(rawName)\(set.suffix)"
                    let key = "\(name)\u{0000}\(sort)"
                    if var existing = merged[key] {
                        if !existing.urls.contains(url) {
                            existing.urls.append(url)
                            merged[key] = existing
                        }
                    } else {
                        merged[key] = MergedQuality(
                            name: name,
                            sort: sort,
                            codecRank: set.codecRank,
                            urls: [url]
                        )
                    }
                }
            }
        }
        let entries = merged.values.sorted {
            if $0.codecRank != $1.codecRank {
                return $0.codecRank < $1.codecRank
            }
            return $0.sort > $1.sort
        }
        return entries.map { entry in
            let lines = entry.urls.map { url in
                LiveLine(
                    name: URL(string: url)?.host ?? url,
                    urls: [url],
                    format: kuaishouStreamFormat(url)
                )
            }
            return LiveQuality(
                id: "\(entry.name)\u{0000}\(entry.sort)",
                name: normalizeKuaishouQualityLabel(entry.name),
                sort: entry.sort,
                lines: lines
            )
        }
    }

    private static func representationsOf(_ descriptor: [String: Any]) -> [Any] {
        if let adaptationSet = LiveJSON.asMap(descriptor["adaptationSet"]),
           let representations = adaptationSet["representation"] as? [Any] {
            return representations
        }
        if let representations = descriptor["representation"] as? [Any] {
            return representations
        }
        return []
    }

    /// Appends `.jpg` when a poster URL carries no image extension;
    /// an empty poster stays empty (never `null.jpg`).
    static func posterUrl(_ poster: String) -> String {
        if poster.isEmpty {
            return ""
        }
        return isImage(poster) ? poster : "\(poster).jpg"
    }

    private static func isImage(_ url: String) -> Bool {
        let imageExtensions: Set<String> = [
            "svgz", "pjp", "png", "ico", "avif", "tiff", "tif", "jfif", "svg",
            "xbm", "pjpeg", "webp", "jpg", "jpeg", "bmp", "gif"
        ]
        if url.isEmpty {
            return false
        }
        let ext = url.components(separatedBy: ".").last?.lowercased().components(separatedBy: "?").first ?? ""
        return imageExtensions.contains(ext)
    }
}

// MARK: - Site

final class KuaishouLiveSite: LiveSiteResolver {
    var platform: LivePlatform {
        .kuaishou
    }

    private let fetcher: LiveDataFetcher

    private static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36",
        "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3",
        "connection": "keep-alive",
        "sec-ch-ua": "Google Chrome;v=107, Chromium;v=107, Not=A?Brand;v=24",
        "sec-ch-ua-platform": "macOS",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "same-origin",
        "Sec-Fetch-User": "?1"
    ]

    private static let roomBaseUrl = "https://live.kuaishou.com/u"

    init(fetcher: LiveDataFetcher? = nil) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
    }

    func makeDanmakuTransport() -> LiveDanmakuTransport {
        KuaishouDanmaku(fetcher: fetcher)
    }

    // MARK: - Room info

    func roomInfo(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        let trimmed = roomId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completion(.failure(LiveError.invalidRoomId))
            return
        }
        loadRoomDetail(roomId: trimmed) { result in
            switch result {
            case .success(let room):
                completion(.success(room))
            case .failure:
                // UI path: a transient failure must not blank the
                // card — return the room as offline.
                completion(.success(LiveRoom(roomId: trimmed, platform: .kuaishou, isLive: false, link: LivePlatform.kuaishou.roomLink(roomId: trimmed))))
            }
        }
    }

    /// Strict room load: throws when the page carries no parseable
    /// playback metadata (resolve must see the transient error,
    /// never a disguised "offline").
    private func loadRoomDetail(roomId: String, completion: @escaping (Result<LiveRoom, Error>) -> Void) {
        guard let url = URL(string: "\(KuaishouLiveSite.roomBaseUrl)/\(roomId)") else {
            completion(.failure(LiveError.parseFailed("快手房间地址无效")))
            return
        }
        var headers = KuaishouLiveSite.headers
        headers["Accept"] = "text/html,application/xhtml+xml"
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                completion(.failure(LiveError.emptyResponse))
                return
            }
            do {
                completion(.success(try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: roomId)))
            } catch {
                completion(.failure(error))
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
        loadRoomDetail(roomId: trimmed) { result in
            switch result {
            case .success(let room):
                if !room.isLive {
                    completion(.failure(LiveError.offline))
                    return
                }
                let playUrls = LiveJSON.asMap(room.data)?["playUrls"]
                let qualities = KuaishouLiveSite.parseKuaishouPlayQualities(playUrls)
                if qualities.isEmpty {
                    completion(.failure(LiveError.offline))
                    return
                }
                let requested = qualities.first { $0.id == quality?.id } ?? qualities[0]
                completion(.success(LivePlayUrlResolution.applying(requested, in: qualities)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
