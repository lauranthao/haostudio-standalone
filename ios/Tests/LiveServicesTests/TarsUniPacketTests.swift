// HAo Studio 2.0 — TARS UniPacket (TUP) tests (S4 leg B).
//
// Encode/decode round-trips, attribute put/get, and the P0-03
// error mapping (non-2xx carries the HTTP status, empty body is
// TupResultError(-1), never a force unwrap). No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class TarsUniPacketTests: XCTestCase {
    private func tokenResponseData(code: Int = 0) throws -> Data {
        let packet = TarsUniPacket()
        packet.servantName = "liveui"
        packet.funcName = "getCdnToken"
        var response = GetCdnTokenExResp()
        response.sFlvToken = "wsSecret=abc&wsTime=6553f5a0"
        response.iExpireTime = 1700001184
        try packet.putStruct("tRsp", response)
        try packet.putInt("", code)
        return try packet.encode()
    }

    func testUniAttributeStructAndIntRoundTrip() throws {
        let attributes = UniAttribute()
        var request = GetCdnTokenExReq()
        request.sFlvUrl = "https://example.com/live"
        request.sStreamName = "stream-1"
        request.iAppId = 66
        try attributes.putStruct("tReq", request)
        try attributes.putInt("count", 7)
        let encoded = try attributes.encode()
        let decoded = UniAttribute()
        try decoded.decode(encoded)
        let restored: GetCdnTokenExReq? = try decoded.structValue(name: "tReq")
        XCTAssertEqual(restored?.sFlvUrl, "https://example.com/live")
        XCTAssertEqual(restored?.sStreamName, "stream-1")
        XCTAssertEqual(restored?.iAppId, 66)
        XCTAssertEqual(decoded.intValue(name: "count"), 7)
        XCTAssertEqual(decoded.intValue(name: "missing"), 0)
    }

    func testRequestPacketEncodeDecodeRoundTrip() throws {
        var request = GetCdnTokenExReq()
        request.sFlvUrl = "https://example.com/live"
        request.sStreamName = "stream-1"
        let client = BaseTarsHttp(baseUrl: "https://wup.huya.com", servantName: "liveui")
        let body = try client.buildRequest(methodName: "getCdnToken", request: request)
        let packet = TarsUniPacket()
        try packet.decode(body)
        XCTAssertEqual(packet.servantName, "liveui")
        XCTAssertEqual(packet.funcName, "getCdnToken")
        let restored: GetCdnTokenExReq? = try packet.responseStruct(name: "tReq")
        XCTAssertEqual(restored?.sFlvUrl, "https://example.com/live")
        XCTAssertEqual(restored?.sStreamName, "stream-1")
    }

    func testDecodeResponseReturnsStructAndCodeZero() throws {
        let data = try tokenResponseData(code: 0)
        let envelope = try BaseTarsHttp.decodeResponse(data, response: GetCdnTokenExResp())
        XCTAssertEqual(envelope.code, 0)
        XCTAssertEqual(envelope.response?.sFlvToken, "wsSecret=abc&wsTime=6553f5a0")
        XCTAssertEqual(envelope.response?.iExpireTime, 1700001184)
    }

    func testDecodeResponseCarriesNonZeroCode() throws {
        let data = try tokenResponseData(code: 1001)
        let envelope = try BaseTarsHttp.decodeResponse(data, response: GetCdnTokenExResp())
        XCTAssertEqual(envelope.code, 1001)
    }

    func testRequestRejectsNon2xxWithHttpStatus() {
        let client = BaseTarsHttp(
            baseUrl: "https://wup.huya.com", servantName: "liveui",
            fetcher: stubFetcher(data: Data("err".utf8), status: 500)
        )
        let expectation = self.expectation(description: "non-2xx")
        client.request(methodName: "getCdnToken", request: GetCdnTokenExReq(), response: GetCdnTokenExResp()) { result in
            if case .failure(let error as TupResultError) = result {
                XCTAssertEqual(error.code, 500)
            } else {
                XCTFail("expected TupResultError(500), got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testRequestRejectsEmptyBodyWithMinusOne() {
        let client = BaseTarsHttp(
            baseUrl: "https://wup.huya.com", servantName: "liveui",
            fetcher: stubFetcher(data: Data(), status: 200)
        )
        let expectation = self.expectation(description: "empty body")
        client.request(methodName: "getCdnToken", request: GetCdnTokenExReq(), response: GetCdnTokenExResp()) { result in
            if case .failure(let error as TupResultError) = result {
                XCTAssertEqual(error.code, -1)
            } else {
                XCTFail("expected TupResultError(-1), got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testRequestDecodesStubbedTokenResponse() throws {
        let data = try tokenResponseData(code: 0)
        let client = BaseTarsHttp(
            baseUrl: "https://wup.huya.com", servantName: "liveui",
            fetcher: stubFetcher(data: data, status: 200)
        )
        let expectation = self.expectation(description: "token")
        client.request(methodName: "getCdnToken", request: GetCdnTokenExReq(), response: GetCdnTokenExResp()) { result in
            if case .success(let response) = result {
                XCTAssertEqual(response.sFlvToken, "wsSecret=abc&wsTime=6553f5a0")
            } else {
                XCTFail("expected success, got \(result)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}
