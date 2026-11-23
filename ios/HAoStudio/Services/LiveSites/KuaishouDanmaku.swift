// HAo Studio 2.0 — Kuaishou danmaku (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/kuaishou/
// kuaishou_danmaku.dart`: HTTP polling, not WebSocket. Polls the
// mobile incremental feed
//   GET https://livev.m.chenzhongtech.com/wap/live/feed
//   GET https://m.gifshow.com/wap/live/feed
// with `liveStreamId` (+ `cursor`), timer-driven, one poll at a
// time: the next poll is scheduled only after the previous request
// finishes, so there are no overlapping timers, duplicate cursors
// or background CPU growth.
//
// Args for `start` (from the room detail's `danmakuData`, with a
// `roomId` fallback — `liveStreamId` is resolved here when it is
// not supplied):
//   - `liveStreamId`: the live stream id (preferred).
//   - `roomId`: author/user id; when `liveStreamId` is absent the
//     room page `https://live.kuaishou.com/u/<roomId>` is scraped
//     once for `window.__INITIAL_STATE__` -> `room.liveStream.id`.
//   - `cookie`: optional session cookie header.
//
// Best-effort: poll failures back off exponentially (max 8 attempts)
// and then report `onClose`; the video keeps playing.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

/// One parsed feed batch: cursor for the next poll, server-suggested
/// delay, and the chat messages in it.
struct KuaishouFeedBatch {
    var cursor: String
    var pullDelaySeconds: TimeInterval
    var messages: [DanmakuMessage]
}

final class KuaishouDanmaku: LiveDanmakuTransport {
    static let feedUrls = [
        "https://livev.m.chenzhongtech.com/wap/live/feed",
        "https://m.gifshow.com/wap/live/feed"
    ]
    static let maxReconnectAttempts = 8
    static let firstPollRetryDelaysMilliseconds = [0, 600, 1400]

    var isConnected: Bool {
        _connected
    }

    var onMessage: ((DanmakuMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var onReconnect: (() -> Void)?

    private let fetcher: LiveDataFetcher

    /// Floor for the poll interval (server may ask for longer).
    private let minimumPollDelaySeconds: TimeInterval

    private var _connected = false
    private var _stopped = false
    private var _generation = 0
    private var _pollWorkItem: DispatchWorkItem?
    private var _liveStreamId: String?
    private var _cookie = ""
    private var _cursor = ""
    private var _reconnectAttempts = 0

    init(fetcher: LiveDataFetcher? = nil, minimumPollDelaySeconds: TimeInterval = 1) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
        self.minimumPollDelaySeconds = minimumPollDelaySeconds
    }

    func start(danmakuData: [String: Any]) {
        _generation += 1
        let generation = _generation
        _stopped = false
        _pollWorkItem?.cancel()
        _pollWorkItem = nil
        _cursor = ""
        _reconnectAttempts = 0
        _connected = false
        _cookie = LiveJSON.asString(danmakuData["cookie"])

        let liveStreamId = LiveJSON.asString(danmakuData["liveStreamId"]).trimmingCharacters(in: .whitespaces)
        if liveStreamId.isEmpty {
            // Fallback: resolve the liveStreamId from the room page.
            let roomId = LiveJSON.asString(danmakuData["roomId"]).trimmingCharacters(in: .whitespaces)
            if roomId.isEmpty {
                onClose?()
                return
            }
            KuaishouDanmaku.resolveLiveStreamId(roomId: roomId, fetcher: fetcher) { [weak self] resolved in
                guard let self = self, generation == self._generation, !self._stopped else {
                    return
                }
                if resolved.isEmpty {
                    self.onClose?()
                    return
                }
                self._liveStreamId = resolved
                self.pollFirst(generation: generation, attempt: 0)
            }
            return
        }
        _liveStreamId = liveStreamId
        pollFirst(generation: generation, attempt: 0)
    }

    func heartbeat() {
        // The incremental HTTP feed is itself the liveness probe.
    }

    func stop() {
        _generation += 1
        _stopped = true
        _pollWorkItem?.cancel()
        _pollWorkItem = nil
        _liveStreamId = nil
        _cursor = ""
        _reconnectAttempts = 0
        _connected = false
        onMessage = nil
        onReconnect = nil
        onClose = nil
        onReady = nil
    }

    // MARK: - Poll loop

    private func pollFirst(generation: Int, attempt: Int) {
        pollOnce(generation: generation) { [weak self] success in
            guard let self = self, generation == self._generation, !self._stopped else {
                return
            }
            if success {
                return
            }
            if attempt + 1 < KuaishouDanmaku.firstPollRetryDelaysMilliseconds.count {
                let delay = KuaishouDanmaku.firstPollRetryDelaysMilliseconds[attempt + 1]
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, generation == self._generation, !self._stopped else {
                        return
                    }
                    self.pollFirst(generation: generation, attempt: attempt + 1)
                }
                self._pollWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
                return
            }
            // First poll failed 3x: best-effort — report via onClose
            // and give up quietly. Never throw out of start():
            // danmaku must not crash the room (Pure Live rethrows
            // here; this port deliberately does not).
            self.onClose?()
        }
    }

    private func pollOnce(generation: Int, completion: @escaping (Bool) -> Void) {
        guard let liveStreamId = _liveStreamId, generation == _generation, !_stopped else {
            completion(false)
            return
        }
        fetchFeed(liveStreamId: liveStreamId, cursor: _cursor, endpointIndex: 0) { [weak self] result in
            guard let self = self, generation == self._generation, !self._stopped else {
                completion(false)
                return
            }
            switch result {
            case .success(let raw):
                do {
                    let batch = try KuaishouDanmaku.parseFeedPayload(raw)
                    if !batch.cursor.isEmpty {
                        self._cursor = batch.cursor
                    }
                    self._reconnectAttempts = 0
                    let wasConnected = self._connected
                    self._connected = true
                    if !wasConnected {
                        self.onReady?()
                    }
                    for message in batch.messages {
                        if generation != self._generation {
                            break
                        }
                        self.onMessage?(message)
                    }
                    self.schedulePoll(generation: generation, delaySeconds: batch.pullDelaySeconds)
                    completion(true)
                } catch {
                    self.handlePollFailure(generation: generation)
                    completion(false)
                }
            case .failure:
                self.handlePollFailure(generation: generation)
                completion(false)
            }
        }
    }

    private func handlePollFailure(generation: Int) {
        _connected = false
        _reconnectAttempts += 1
        if _reconnectAttempts > KuaishouDanmaku.maxReconnectAttempts {
            onClose?()
            return
        }
        if _reconnectAttempts == 1 {
            onReconnect?()
        }
        let seconds = 1 << min(_reconnectAttempts - 1, 3)
        schedulePoll(generation: generation, delaySeconds: TimeInterval(seconds))
    }

    private func schedulePoll(generation: Int, delaySeconds: TimeInterval) {
        if generation != _generation {
            return
        }
        _pollWorkItem?.cancel()
        let delay = max(delaySeconds, minimumPollDelaySeconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, generation == self._generation, !self._stopped else {
                return
            }
            self._pollWorkItem = nil
            self.pollOnce(generation: generation) { _ in }
        }
        _pollWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Feed fetch

    private func fetchFeed(liveStreamId: String, cursor: String, endpointIndex: Int, completion: @escaping (Result<Any, Error>) -> Void) {
        if endpointIndex >= KuaishouDanmaku.feedUrls.count {
            completion(.failure(LiveError.transportFailed("快手弹幕源全部失败")))
            return
        }
        var components = URLComponents(string: KuaishouDanmaku.feedUrls[endpointIndex])
        var items = [URLQueryItem(name: "liveStreamId", value: liveStreamId)]
        if !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            fetchFeed(liveStreamId: liveStreamId, cursor: cursor, endpointIndex: endpointIndex + 1, completion: completion)
            return
        }
        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Linux; Android 16; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0 Mobile Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://livev.m.chenzhongtech.com/"
        ]
        if !_cookie.trimmingCharacters(in: .whitespaces).isEmpty {
            headers["cookie"] = _cookie.trimmingCharacters(in: .whitespaces)
        }
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { [weak self] data, status, error in
            guard let self = self else {
                completion(.failure(LiveError.transportFailed("快手弹幕已停止")))
                return
            }
            if error != nil {
                self.fetchFeed(liveStreamId: liveStreamId, cursor: cursor, endpointIndex: endpointIndex + 1, completion: completion)
                return
            }
            guard let status = status, (200..<300).contains(status), let data = data else {
                self.fetchFeed(liveStreamId: liveStreamId, cursor: cursor, endpointIndex: endpointIndex + 1, completion: completion)
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
                completion(.success(json))
            } catch {
                self.fetchFeed(liveStreamId: liveStreamId, cursor: cursor, endpointIndex: endpointIndex + 1, completion: completion)
            }
        }
    }

    /// Resolve `liveStreamId` from the room HTML page
    /// (`window.__INITIAL_STATE__` -> `room.liveStream.id`).
    /// Best-effort: returns '' on any failure.
    static func resolveLiveStreamId(roomId: String, fetcher: LiveDataFetcher, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://live.kuaishou.com/u/\(roomId)") else {
            completion("")
            return
        }
        let headers: [String: String] = [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        ]
        let request = LiveHTTP.getRequest(url: url, headers: headers)
        fetcher(request) { data, _, _ in
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion("")
                return
            }
            do {
                let room = try KuaishouLiveSite.parseKuaishouRoomPage(html: html, roomId: roomId)
                completion(LiveJSON.asString(room.danmakuData?["liveStreamId"]))
            } catch {
                completion("")
            }
        }
    }

    // MARK: - Feed parse

    /// Parse one feed payload (decoded JSON, a JSON string, or a
    /// double-encoded string) into a batch. Throws on an invalid
    /// shape or a non-1 `result`.
    static func parseFeedPayload(_ raw: Any?) throws -> KuaishouFeedBatch {
        var payload: Any? = raw
        for _ in 0..<3 {
            guard let text = payload as? String else {
                break
            }
            guard let data = text.data(using: .utf8) else {
                throw LiveError.parseFailed("快手弹幕数据不是有效 JSON")
            }
            payload = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        }
        if let map = payload as? [String: Any], map["data"] is [String: Any] {
            payload = map["data"]
        }
        guard let map = payload as? [String: Any] else {
            throw LiveError.parseFailed("快手弹幕数据格式无效")
        }
        let result = LiveJSON.asIntOrNil(map["result"])
        if result != 1 {
            throw LiveError.apiRejected(code: result ?? -1, message: "快手弹幕请求被拒绝")
        }
        let cursor = LiveJSON.asString(map["cursor"])
        let pullSeconds = min(max(LiveJSON.asIntOrNil(map["pullCycleSeconds"]) ?? 3, 1), 10)
        var messages: [DanmakuMessage] = []
        if let feeds = map["liveStreamFeeds"] as? [Any] {
            for feed in feeds {
                guard let feed = feed as? [String: Any] else {
                    continue
                }
                if LiveJSON.asString(feed["type"]).lowercased() != "comment" {
                    continue
                }
                let content = LiveJSON.asString(feed["content"]).trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    continue
                }
                let author = LiveJSON.asMap(feed["author"])
                let userName = LiveJSON.asString(author?["userName"]).trimmingCharacters(in: .whitespaces)
                messages.append(DanmakuMessage(
                    userName: userName.isEmpty ? "快手用户" : userName,
                    text: content
                ))
            }
        }
        return KuaishouFeedBatch(
            cursor: cursor,
            pullDelaySeconds: TimeInterval(pullSeconds),
            messages: messages
        )
    }
}
