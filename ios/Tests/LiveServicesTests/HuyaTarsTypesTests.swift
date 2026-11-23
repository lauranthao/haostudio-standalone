// HAo Studio 2.0 — Huya TARS struct tests (S4 leg B).
//
// Encode/decode round-trips for the WUP + danmaku structs.
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class HuyaTarsTypesTests: XCTestCase {
    private func roundTrip<T: TarsStruct>(_ value: T) throws -> T {
        let output = TarsOutputStream()
        value.write(to: output)
        var decoded = T()
        try decoded.read(from: TarsInputStream(output.bytes))
        return decoded
    }

    func testHuyaUserIdRoundTrip() throws {
        var user = HuyaUserId()
        user.lUid = 1400000012345
        user.sGuid = "abcdef0123456789abcdef0123456789"
        user.sToken = "tok"
        user.sHuYaUA = "HYSDK(Windows,30000002)"
        user.iTokenType = 2
        let decoded = try roundTrip(user)
        XCTAssertEqual(decoded.lUid, 1400000012345)
        XCTAssertEqual(decoded.sGuid, "abcdef0123456789abcdef0123456789")
        XCTAssertEqual(decoded.sToken, "tok")
        XCTAssertEqual(decoded.iTokenType, 2)
    }

    func testGetCdnTokenExReqDefaultsAppId66() throws {
        var request = GetCdnTokenExReq()
        request.sFlvUrl = "https://al.huya.com/"
        request.sStreamName = "stream-1"
        request.iLoopTime = 0
        let decoded = try roundTrip(request)
        XCTAssertEqual(decoded.sFlvUrl, "https://al.huya.com/")
        XCTAssertEqual(decoded.sStreamName, "stream-1")
        XCTAssertEqual(decoded.iAppId, 66)
    }

    func testGetCdnTokenExRespRoundTrip() throws {
        var response = GetCdnTokenExResp()
        response.sFlvToken = "wsSecret=x&wsTime=6553f5a0"
        response.iExpireTime = 1700001184
        let decoded = try roundTrip(response)
        XCTAssertEqual(decoded.sFlvToken, "wsSecret=x&wsTime=6553f5a0")
        XCTAssertEqual(decoded.iExpireTime, 1700001184)
    }

    func testHyPushMessageRoundTrip() throws {
        var push = HYPushMessage()
        push.pushType = 0
        push.uri = 1400
        push.msg = Data("hello".utf8)
        push.protocolType = 0
        let decoded = try roundTrip(push)
        XCTAssertEqual(decoded.uri, 1400)
        XCTAssertEqual(decoded.msg, Data("hello".utf8))
    }

    func testHyMessageItemListRoundTrip() throws {
        var first = HYMessageItem()
        first.uri = 1400
        first.msg = Data("one".utf8)
        first.messageId = 11
        var second = HYMessageItem()
        second.uri = 8001
        second.msg = Data("two".utf8)
        second.messageId = 22
        var push = HYPushMessageV2()
        push.groupId = "g1"
        push.items = [first, second]
        let decoded = try roundTrip(push)
        XCTAssertEqual(decoded.groupId, "g1")
        XCTAssertEqual(decoded.items.count, 2)
        XCTAssertEqual(decoded.items[0].uri, 1400)
        XCTAssertEqual(decoded.items[0].messageId, 11)
        XCTAssertEqual(decoded.items[1].uri, 8001)
        XCTAssertEqual(decoded.items[1].messageId, 22)
    }

    func testHyMessageRoundTripWithSenderAndFormat() throws {
        var sender = HYSender()
        sender.uid = 999
        sender.nickName = "主播"
        sender.gender = 1
        var format = HYBulletFormat()
        format.fontColor = 16711680
        format.fontSize = 4
        format.textSpeed = 0
        format.transitionType = 1
        var message = HYMessage()
        message.userInfo = sender
        message.content = "你好"
        message.bulletFormat = format
        let decoded = try roundTrip(message)
        XCTAssertEqual(decoded.userInfo.nickName, "主播")
        XCTAssertEqual(decoded.userInfo.uid, 999)
        XCTAssertEqual(decoded.content, "你好")
        XCTAssertEqual(decoded.bulletFormat.fontColor, 16711680)
    }

    func testHySenderLmidMirrorsUidPerDartQuirk() throws {
        var sender = HYSender()
        sender.uid = 777
        sender.lMid = 12345
        let decoded = try roundTrip(sender)
        // Pure Live reads lMid from tag 0 as well (same value as uid);
        // the port keeps that quirk, so lMid decodes as uid.
        XCTAssertEqual(decoded.uid, 777)
        XCTAssertEqual(decoded.lMid, 777)
    }
}
