// HAo Studio 2.0 — Huya danmaku tests (S4 leg B).
//
// Join/heartbeat bytes, push decode (1400/8001/8006/2001314),
// super-chat panel + refresh pipeline. Fixtures are built with
// the real TARS encoder. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class HuyaDanmakuTests: XCTestCase {
    private func makeTransport(
        socket: FakeDanmakuSocket? = nil,
        superChatFetcher: ((Int, @escaping (Result<[HuyaSuperChatMessage], Error>) -> Void) -> Void)? = nil
    ) -> HuyaDanmaku {
        HuyaDanmaku(
            wupClient: HuyaWupClient(fetcher: stubFetcher(data: nil, status: 404)),
            socket: socket,
            superChatFetcher: superChatFetcher
        )
    }

    private func wrapPush(_ push: HYPushMessage) throws -> Data {
        let inner = TarsOutputStream()
        push.write(to: inner)
        let outer = TarsOutputStream()
        try outer.writeInt(7, tag: 0)
        try outer.writeBytes(inner.bytes, tag: 1)
        return outer.bytes
    }

    private func chatPush(nick: String, content: String, color: Int = 0) throws -> Data {
        var sender = HYSender()
        sender.nickName = nick
        var format = HYBulletFormat()
        format.fontColor = color
        var message = HYMessage()
        message.userInfo = sender
        message.content = content
        message.bulletFormat = format
        let encoded = TarsOutputStream()
        message.write(to: encoded)
        var push = HYPushMessage()
        push.uri = 1400
        push.msg = encoded.bytes
        return try wrapPush(push)
    }

    // MARK: - Join / heartbeat bytes

    func testJoinDataEncodesGroupJoin() throws {
        let data = HuyaDanmaku.joinData(topSid: 111)
        let outer = TarsInputStream(data)
        XCTAssertEqual(try outer.readInt(tag: 0), 16)
        let group = TarsInputStream(try outer.readBytes(tag: 1))
        XCTAssertEqual(try group.readStringList(tag: 0), ["live:111", "chat:111"])
        XCTAssertEqual(try group.readString(tag: 1), "")
    }

    func testHeartbeatDataEncodesCommand20() throws {
        let data = HuyaDanmaku.heartbeatData
        let stream = TarsInputStream(data)
        XCTAssertEqual(try stream.readInt(tag: 0), 20)
        XCTAssertEqual(try stream.readBytes(tag: 1).count, 0)
    }

    func testStartConnectsAndJoins() {
        let socket = FakeDanmakuSocket()
        let transport = makeTransport(socket: socket)
        transport.start(danmakuData: ["uid": 98765, "topSid": 111, "subSid": 222])
        XCTAssertEqual(socket.connectedUrls, [URL(string: "wss://wsapi.huya.com")!])
        XCTAssertTrue(transport.isConnected)
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertEqual(socket.sent[0], HuyaDanmaku.joinData(topSid: 111))
        XCTAssertEqual(socket.sent[1], HuyaDanmaku.heartbeatData)
        transport.stop()
        XCTAssertFalse(transport.isConnected)
    }

    func testStartWithoutTopSidAndRoomIdCloses() {
        let transport = makeTransport()
        var closed = false
        transport.onClose = { closed = true }
        transport.start(danmakuData: [:])
        XCTAssertTrue(closed)
    }

    // MARK: - Push decode

    func testDecodeChatMessage() throws {
        let transport = makeTransport()
        var received: [DanmakuMessage] = []
        transport.onMessage = { received.append($0) }
        transport.decodeMessage(try chatPush(nick: "主播", content: "你好", color: 16711680))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].userName, "主播")
        XCTAssertEqual(received[0].text, "你好")
        XCTAssertEqual(received[0].colorArgb, 0xFFFF0000)
    }

    func testDecodeChatMessageWithoutColorIsWhite() throws {
        let transport = makeTransport()
        var received: [DanmakuMessage] = []
        transport.onMessage = { received.append($0) }
        transport.decodeMessage(try chatPush(nick: "a", content: "hi"))
        XCTAssertEqual(received[0].colorArgb, 0xFFFFFFFF)
    }

    func testDecodeAttendeeCountIsSkipped() throws {
        let transport = makeTransport()
        var received: [DanmakuMessage] = []
        transport.onMessage = { received.append($0) }
        var push = HYPushMessage()
        push.uri = 8006
        push.msg = Data([0x01, 0x02])
        transport.decodeMessage(try wrapPush(push))
        XCTAssertTrue(received.isEmpty)
    }

    func testDecodePresenterUidEndsStream() throws {
        let transport = makeTransport()
        transport.setTestArgs(HuyaDanmakuArgs(uid: 98765, topSid: 111, subSid: 222))
        var closed = false
        transport.onClose = { closed = true }
        let uidBytes = TarsOutputStream()
        try uidBytes.writeInt(98765, tag: 0)
        var push = HYPushMessage()
        push.uri = 8001
        push.msg = uidBytes.bytes
        transport.decodeMessage(try wrapPush(push))
        XCTAssertTrue(closed)
    }

    func testDecodeOtherPresenterUidDoesNotEndStream() throws {
        let transport = makeTransport()
        transport.setTestArgs(HuyaDanmakuArgs(uid: 98765, topSid: 111, subSid: 222))
        var closed = false
        transport.onClose = { closed = true }
        let uidBytes = TarsOutputStream()
        try uidBytes.writeInt(555, tag: 0)
        var push = HYPushMessage()
        push.uri = 8001
        push.msg = uidBytes.bytes
        transport.decodeMessage(try wrapPush(push))
        XCTAssertFalse(closed)
    }

    func testDecodeMalformedFrameIsDropped() {
        let transport = makeTransport()
        var received: [DanmakuMessage] = []
        transport.onMessage = { received.append($0) }
        transport.decodeMessage(Data([0xFF, 0x00, 0x01]))
        transport.decodeMessage(Data())
        XCTAssertTrue(received.isEmpty)
    }

    func testDecodeV2PushItems() throws {
        let transport = makeTransport()
        var received: [DanmakuMessage] = []
        transport.onMessage = { received.append($0) }
        var sender = HYSender()
        sender.nickName = "v2"
        var message = HYMessage()
        message.userInfo = sender
        message.content = "v2 chat"
        let encoded = TarsOutputStream()
        message.write(to: encoded)
        var item = HYMessageItem()
        item.uri = 1400
        item.msg = encoded.bytes
        item.messageId = 42
        var push = HYPushMessageV2()
        push.groupId = "g"
        push.items = [item]
        let inner = TarsOutputStream()
        push.write(to: inner)
        let outer = TarsOutputStream()
        try outer.writeInt(22, tag: 0)
        try outer.writeBytes(inner.bytes, tag: 1)
        transport.decodeMessage(outer.bytes)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].text, "v2 chat")
    }

    // MARK: - Super chat

    private func panelBytes() throws -> Data {
        var user = HuyaMessageUser()
        user.sNick = "老板"
        user.sAvatar = "https://a/b.jpg"
        var item = GameEventMessageBoardInfo()
        item.tMessageUser = user
        item.sContent = "醒目留言"
        item.iCost = 0
        item.iCostPay = 500
        item.iTotalSec = 60
        item.iCountDown = 30
        item.lMessageId = 42
        var panel = GameEventMessageBoardPanel()
        panel.vGameEventMessageBoardInfo = [item]
        let output = TarsOutputStream()
        panel.write(to: output)
        return output.bytes
    }

    func testSuperChatsFromPanelPayload() throws {
        let chats = HuyaDanmaku.superChatsFromPanel(try panelBytes())
        XCTAssertEqual(chats?.count, 1)
        XCTAssertEqual(chats?[0].message, "醒目留言")
        XCTAssertEqual(chats?[0].price, 5)
        XCTAssertEqual(chats?[0].messageId, "huya:42")
        XCTAssertNil(HuyaDanmaku.superChatsFromPanel(Data()))
        XCTAssertNil(HuyaDanmaku.superChatsFromPanel(Data([0x01, 0x02])))
    }

    func testHeadlineBroadcastTriggersBoardRefresh() throws {
        let chat = HuyaSuperChatMessage(
            messageId: "huya:42", userName: "老板", message: "醒目留言",
            price: 5, startTime: Date(), endTime: Date(), face: ""
        )
        let transport = makeTransport(superChatFetcher: { _, completion in
            completion(.success([chat]))
        })
        transport.setTestArgs(HuyaDanmakuArgs(uid: 1, topSid: 111, subSid: 222))
        var received: [DanmakuMessage] = []
        transport.onMessage = { received.append($0) }
        transport.decodeMessage(try chatPush(nick: "x", content: "xxx(来自一元上头条)"))
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].text, "xxx(来自一元上头条)")
        XCTAssertTrue(received[1].isSuperChat)
        XCTAssertEqual(received[1].text, "💰 ¥5 醒目留言")
        // The same board item is never emitted twice.
        transport.decodeMessage(try chatPush(nick: "x", content: "yyy(来自十元上头条)"))
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[2].text, "yyy(来自十元上头条)")
    }
}
