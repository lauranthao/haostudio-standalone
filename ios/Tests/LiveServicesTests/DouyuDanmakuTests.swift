// HAo Studio 2.0 — Douyu danmaku tests (S4 leg B).
//
// STT framing, colour map, chat/super-chat/rss-close.
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class DouyuDanmakuTests: XCTestCase {
    private func transport(socket: FakeDanmakuSocket? = nil) -> DouyuDanmaku {
        DouyuDanmaku(socket: socket)
    }

    func testSerializeDeserializeRoundTrip() {
        let body = "type@=chatmsg/rid@=123456/txt@=你好/"
        let frame = DouyuDanmaku.serializeDouyu(body)
        XCTAssertEqual(DouyuDanmaku.deserializeDouyu(frame), body)
        XCTAssertNil(DouyuDanmaku.deserializeDouyu(Data([0x01, 0x02])))
        XCTAssertNil(DouyuDanmaku.deserializeDouyu(Data()))
    }

    func testSttParsing() {
        let parsed = DouyuDanmaku.sttToJObject("type@=chatmsg/nn@=用户/col@=1/txt@=你好/") as? [String: Any]
        XCTAssertEqual(parsed?["type"] as? String, "chatmsg")
        XCTAssertEqual(parsed?["nn"] as? String, "用户")
        XCTAssertEqual(parsed?["col"] as? String, "1")
        XCTAssertEqual(parsed?["txt"] as? String, "你好")
    }

    func testSttListAndUnescape() {
        let parsed = DouyuDanmaku.sttToJObject("a@=1//b@=2/") as? [Any]
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual((parsed?[0] as? [String: Any])?["a"] as? String, "1")
        XCTAssertEqual((parsed?[1] as? [String: Any])?["b"] as? String, "2")
        let escaped = DouyuDanmaku.sttToJObject("txt@=a@Sslash@Aat/") as? [String: Any]
        XCTAssertEqual(escaped?["txt"] as? String, "a/slash@at")
    }

    func testColorMap() {
        XCTAssertEqual(DouyuDanmaku.douyuColorArgb(1), 0xFFFF0000)
        XCTAssertEqual(DouyuDanmaku.douyuColorArgb(2), 0xFF1E87F0)
        XCTAssertEqual(DouyuDanmaku.douyuColorArgb(3), 0xFF7AC84B)
        XCTAssertEqual(DouyuDanmaku.douyuColorArgb(4), 0xFFFF7F00)
        XCTAssertEqual(DouyuDanmaku.douyuColorArgb(5), 0xFF9B39F4)
        XCTAssertEqual(DouyuDanmaku.douyuColorArgb(6), 0xFFFF69B4)
        XCTAssertEqual(DouyuDanmaku.douyuColorArgb(99), 0xFFFFFFFF)
    }

    func testStartSendsLoginAndJoin() {
        let socket = FakeDanmakuSocket()
        let danmaku = transport(socket: socket)
        danmaku.start(danmakuData: ["roomId": "123456"])
        XCTAssertEqual(socket.connectedUrls, [URL(string: "wss://danmuproxy.douyu.com:8506")!])
        XCTAssertTrue(danmaku.isConnected)
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertEqual(DouyuDanmaku.deserializeDouyu(socket.sent[0]), "type@=loginreq/roomid@=123456/")
        XCTAssertEqual(DouyuDanmaku.deserializeDouyu(socket.sent[1]), "type@=joingroup/rid@=123456/gid@=-9999/")
        danmaku.stop()
    }

    func testStartWithoutRoomIdCloses() {
        let danmaku = transport()
        var closed = false
        danmaku.onClose = { closed = true }
        danmaku.start(danmakuData: [:])
        XCTAssertTrue(closed)
    }

    private func decodeOne(_ body: String) -> (messages: [DanmakuMessage], closed: Bool) {
        let danmaku = transport()
        var received: [DanmakuMessage] = []
        var closed = false
        danmaku.onMessage = { received.append($0) }
        danmaku.onClose = { closed = true }
        danmaku.decodeMessage(DouyuDanmaku.serializeDouyu(body))
        return (received, closed)
    }

    func testDecodeChatMessage() {
        let result = decodeOne("type@=chatmsg/rid@=123456/uid@=1/nn@=用户/col@=1/txt@=你好/dms@=/ifs@=0/")
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].text, "你好")
        XCTAssertEqual(result.messages[0].userName, "用户")
        XCTAssertEqual(result.messages[0].colorArgb, 0xFFFF0000)
        XCTAssertFalse(result.messages[0].suspectedAutomated)
        XCTAssertFalse(result.closed)
    }

    func testDecodeChatMessageFlagsBotWhenNoDms() {
        let result = decodeOne("type@=chatmsg/rid@=123456/uid@=1/nn@=机器人/col@=2/txt@=广告/ifs@=0/")
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertTrue(result.messages[0].suspectedAutomated)
        let human = decodeOne("type@=chatmsg/rid@=123456/uid@=1/nn@=真人/col@=2/txt@=hi/ifs@=1/")
        XCTAssertFalse(human.messages[0].suspectedAutomated)
    }

    func testDecodeSuperChatNested() {
        let body = "type@=comm_chatmsg/chatmsg@=type@A=chatmsg@Snn@A=大佬@Stxt@A=醒目@Scprice@A=5000/"
        let result = decodeOne(body)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].text, "💰 ¥50 醒目")
        XCTAssertEqual(result.messages[0].userName, "大佬")
        XCTAssertTrue(result.messages[0].isSuperChat)
    }

    func testDecodeRoomClosedEndsTransport() {
        let result = decodeOne("type@=rss/ss@=0/")
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertTrue(result.closed)
        let live = decodeOne("type@=rss/ss@=1/")
        XCTAssertFalse(live.closed)
    }

    func testDecodeMalformedIsDropped() {
        let danmaku = transport()
        var received: [DanmakuMessage] = []
        danmaku.onMessage = { received.append($0) }
        danmaku.decodeMessage(Data([0x01, 0x02, 0x03]))
        danmaku.decodeMessage(Data())
        danmaku.decodeMessage(DouyuDanmaku.serializeDouyu("not stt at all"))
        XCTAssertTrue(received.isEmpty)
    }
}
