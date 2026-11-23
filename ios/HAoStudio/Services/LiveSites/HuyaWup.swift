// HAo Studio 2.0 — Huya WUP calls (S4 leg B).
//
// Swift port of the Flutter `lib/shared/platforms/huya/huya_wup.dart`
// (itself a port of the WUP pieces of Pure Live 3.x `huya_site.dart`
// + `huya_utils.dart`).
//
// Two WUP contracts:
//
// 1. Native playback token (`getCdnTokenInfoEx`, servant `liveui`):
//    the long-lived FLV anti-code. The web-template path signs a
//    ~120 s transport lease; the native WUP token outlives it (~420 s
//    in Pure Live's probes). It is FLV-only — NEVER reuse it for HLS.
// 2. Super-chat message board (`getHeadLineMessageBoard`, servant
//    `wupui`): the HTTP fallback for 醒目留言. The WS only carries a
//    uri-2001314 board notification; the board itself is fetched here.
//
// Timeouts are SECONDS, explicit (P0-03): the token client uses 6 s,
// the board client 2 s.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Viewer identity

/// Anonymous viewer identity for WUP calls. The site resolves it
/// from `POST https://udblgn.huya.com/web/anonymousLogin` and falls
/// back to a stable process-local uid when that endpoint fails.
struct HuyaViewerIdentity {
    var uid: Int
    var guid: String
    var isAnonymous: Bool

    init(uid: Int, guid: String, isAnonymous: Bool = true) {
        self.uid = uid
        self.guid = guid
        self.isAnonymous = isAnonymous
    }
}

// MARK: - Super chat

/// One 醒目留言 (super chat) from the message board.
struct HuyaSuperChatMessage {
    var messageId: String
    var userName: String
    var message: String
    var price: Int
    var startTime: Date
    var endTime: Date
    var face: String

    init(messageId: String = "", userName: String = "", message: String = "", price: Int = 0, startTime: Date = Date(), endTime: Date = Date(), face: String = "") {
        self.messageId = messageId
        self.userName = userName
        self.message = message
        self.price = price
        self.startTime = startTime
        self.endTime = endTime
        self.face = face
    }
}

// MARK: - CDN token lease

/// Long-lived FLV credential from native WUP (`HuyaCdnTokenLease`
/// in the Dart port). `invalidAt` is the hard expiry (wsTime + 5
/// min, capped by the server's `iExpireTime` when earlier);
/// `refreshAt` is 30 s before it — the player refreshes the WUP
/// token before expiry and never extends `wsTime` locally.
struct HuyaCdnTokenLease {
    var antiCode: String
    var invalidAt: Date
    var refreshAt: Date
    var serverExpireValue: Int

    static func from(response: GetCdnTokenExResp, now: Date = Date()) throws -> HuyaCdnTokenLease {
        let antiCode = response.sFlvToken.trimmingCharacters(in: .whitespaces)
        if antiCode.isEmpty {
            throw LiveError.parseFailed("虎牙 WUP 返回了空的 FLV token")
        }
        guard let wsTimeSeconds = Int(LiveQuery.value(antiCode, key: "wsTime") ?? "", radix: 16) else {
            throw LiveError.parseFailed("虎牙 WUP token 没有有效的 wsTime")
        }
        var invalidAt = Date(timeIntervalSince1970: TimeInterval(wsTimeSeconds)).addingTimeInterval(300)
        let current = now
        let serverExpiry = response.iExpireTime
        if serverExpiry > 0 {
            let serverInvalidAt: Date
            if serverExpiry > 1000000000000 {
                serverInvalidAt = Date(timeIntervalSince1970: TimeInterval(serverExpiry) / 1000)
            } else if serverExpiry > 1000000000 {
                serverInvalidAt = Date(timeIntervalSince1970: TimeInterval(serverExpiry))
            } else {
                serverInvalidAt = current.addingTimeInterval(TimeInterval(serverExpiry))
            }
            if serverInvalidAt < invalidAt {
                invalidAt = serverInvalidAt
            }
        }
        return HuyaCdnTokenLease(
            antiCode: antiCode,
            invalidAt: invalidAt,
            refreshAt: invalidAt.addingTimeInterval(-30),
            serverExpireValue: serverExpiry
        )
    }

    func needsRefresh(_ date: Date) -> Bool {
        date >= refreshAt
    }

    func isExpired(_ date: Date) -> Bool {
        date >= invalidAt
    }
}

// MARK: - Request builders

enum HuyaWupRequests {
    /// Web-identity token constants (Pure Live HuyaSite): the web
    /// bundle passes `webh5&0.1.0&websocket` as the UA, app id 66,
    /// loop time 0.
    static let webPlaybackTarsUserAgent = "webh5&0.1.0&websocket"
    static let webPlaybackAppId = 66
    static let webPlaybackTokenLoopTime = 0

    /// Native-play user agent for the WUP token client (the HYSDK UA).
    static let nativePlayUserAgent = "HYSDK(Windows,30000002)_APP(pc_exe&7100004&official)_SDK(trans&2.40.0.6448)"

    /// Native token request: stream name + a random SDK UA. No viewer
    /// uid/guid — the native contract identifies by SDK UA, not by
    /// the anonymous web identity.
    static func nativePlaybackTokenRequest(line: HuyaLine) -> GetCdnTokenExReq {
        var request = GetCdnTokenExReq()
        request.sStreamName = line.streamName
        var userId = HuyaUserId()
        userId.sHuYaUA = HuyaRequestParams.randomSdkUserAgent()
        request.tId = userId
        return request
    }

    /// Web-identity token request (the fallback when the room's own
    /// FLV template cannot be signed). Uses the anonymous viewer
    /// identity + webh5 UA, NOT the native SDK identity.
    static func playbackTokenRequest(line: HuyaLine, viewer: HuyaViewerIdentity, cookie: String = "") -> GetCdnTokenExReq {
        var request = GetCdnTokenExReq()
        request.sFlvUrl = HuyaAntiCode.secureCdnBase(line.baseUrl)
        request.sStreamName = line.streamName
        request.iLoopTime = webPlaybackTokenLoopTime
        request.tId = playbackTokenUserId(viewer: viewer, cookie: cookie)
        request.iAppId = webPlaybackAppId
        return request
    }

    /// Huya's web bundle passes the webh5 UA + the page cookie,
    /// rather than the desktop HYSDK identity used by unrelated
    /// legacy WUP calls.
    static func playbackTokenUserId(viewer: HuyaViewerIdentity, cookie: String = "") -> HuyaUserId {
        var userId = HuyaUserId()
        userId.lUid = viewer.uid
        userId.sGuid = viewer.guid
        userId.sToken = ""
        userId.sHuYaUA = webPlaybackTarsUserAgent
        userId.sCookie = cookie
        userId.iTokenType = 0
        return userId
    }

    /// Super-chat board request for one room (topSid).
    static func messageBoardRequest(lPid: Int, pageSize: Int = 50) -> GetGameEventMessageBoardReq {
        var request = GetGameEventMessageBoardReq()
        request.lPid = lPid
        var userId = HuyaUserId()
        userId.sHuYaUA = nativePlayUserAgent
        request.tId = userId
        request.iMessageBoardScope = 0
        request.iPageSize = pageSize
        return request
    }
}

// MARK: - WUP client

/// The two Huya WUP clients. Each call owns its client; timeouts
/// are in SECONDS (P0-03). The fetcher is injectable so tests stub
/// the transport without touching the network.
final class HuyaWupClient {
    static let wupBaseUrl = "https://wup.huya.com"

    private let fetcher: LiveDataFetcher

    init(fetcher: LiveDataFetcher? = nil) {
        self.fetcher = fetcher ?? LiveHTTP.defaultFetcher
    }

    private func tokenClient() -> BaseTarsHttp {
        BaseTarsHttp(
            baseUrl: HuyaWupClient.wupBaseUrl,
            servantName: "liveui",
            timeoutSeconds: 6,
            headers: [
                "Origin": HuyaRequestParams.baseUrl,
                "Referer": HuyaRequestParams.baseUrl + "/",
                "User-Agent": HuyaWupRequests.nativePlayUserAgent
            ],
            fetcher: fetcher
        )
    }

    private func boardClient() -> BaseTarsHttp {
        BaseTarsHttp(
            baseUrl: HuyaWupClient.wupBaseUrl,
            servantName: "wupui",
            timeoutSeconds: 2,
            headers: HuyaRequestParams.requestHeaders,
            fetcher: fetcher
        )
    }

    /// Fetches the native FLV token for one line via WUP
    /// `getCdnTokenInfoEx` (servant `liveui`). Throws on transport
    /// error, non-zero TUP code, an empty token, or a token without
    /// a valid wsTime. Callers fall back to the web-template
    /// anti-code.
    func fetchNativeCdnToken(line: HuyaLine, completion: @escaping (Result<HuyaCdnTokenLease, Error>) -> Void) {
        let request = HuyaWupRequests.nativePlaybackTokenRequest(line: line)
        tokenClient().request(methodName: "getCdnTokenInfoEx", request: request, response: GetCdnTokenExResp()) { result in
            switch result {
            case .success(let response):
                do {
                    completion(.success(try HuyaCdnTokenLease.from(response: response)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Fetches the web-identity FLV token for one line (same WUP
    /// method, different request identity). Same throw/fallback
    /// contract as `fetchNativeCdnToken`.
    func fetchWebCdnToken(line: HuyaLine, viewer: HuyaViewerIdentity, cookie: String = "", completion: @escaping (Result<HuyaCdnTokenLease, Error>) -> Void) {
        let request = HuyaWupRequests.playbackTokenRequest(line: line, viewer: viewer, cookie: cookie)
        tokenClient().request(methodName: "getCdnTokenInfoEx", request: request, response: GetCdnTokenExResp()) { result in
            switch result {
            case .success(let response):
                do {
                    completion(.success(try HuyaCdnTokenLease.from(response: response)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Fetches the super-chat message board for one room (Pure Live
    /// `getHuyaSuperChatMessageList`, `POST https://wup.huya.com`,
    /// `getHeadLineMessageBoard`). With `first`, only the newest 10
    /// are kept so one fetch never floods the danmaku area;
    /// otherwise only the newest item is returned. Newest first (by
    /// start time, descending).
    func fetchSuperChatMessageList(lPid: Int, first: Bool = false, completion: @escaping (Result<[HuyaSuperChatMessage], Error>) -> Void) {
        let request = HuyaWupRequests.messageBoardRequest(lPid: lPid)
        boardClient().request(methodName: "getHeadLineMessageBoard", request: request, response: GetGameEventMessageBoardRsp()) { result in
            switch result {
            case .success(let response):
                var messages = HuyaWupClient.superChatsFromPanel(response.tMessageBoardPanel)
                messages.sort { $0.startTime > $1.startTime }
                if first {
                    completion(.success(Array(messages.prefix(10))))
                } else if messages.isEmpty {
                    completion(.success([]))
                } else {
                    completion(.success([messages[0]]))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Maps a message-board panel to super-chat messages. Skips
    /// empty content and entries whose display window already ended
    /// (`remainSec <= 0`). Price falls back to `iCostPay / 100`
    /// (rounded, min 1) when `iCost` is 0.
    static func superChatsFromPanel(_ panel: GameEventMessageBoardPanel, now: Date = Date()) -> [HuyaSuperChatMessage] {
        var messages: [HuyaSuperChatMessage] = []
        for item in panel.vGameEventMessageBoardInfo {
            let content = item.sContent.trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                continue
            }
            let remainSeconds = item.iCountDown > 0 ? item.iCountDown : item.iTotalSec
            if remainSeconds <= 0 {
                continue
            }
            let totalSeconds = item.iTotalSec > 0 ? item.iTotalSec : remainSeconds
            var price = item.iCost
            if price <= 0 && item.iCostPay > 0 {
                price = max(1, Int((Double(item.iCostPay) / 100).rounded()))
            }
            let endTime = now.addingTimeInterval(TimeInterval(remainSeconds))
            let startTime = endTime.addingTimeInterval(TimeInterval(-totalSeconds))
            messages.append(HuyaSuperChatMessage(
                messageId: item.lMessageId > 0 ? "huya:\(item.lMessageId)" : "",
                userName: item.tMessageUser.sNick.trimmingCharacters(in: .whitespaces),
                message: content,
                price: price,
                startTime: startTime,
                endTime: endTime,
                face: item.tMessageUser.sAvatar
            ))
        }
        return messages
    }
}
