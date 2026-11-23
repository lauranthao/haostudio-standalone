// HAo Studio 2.0 — pure-Swift inflate tests (S4 leg B).
//
// Fixtures are base64 zlib/gzip blobs generated with Python
// (zlib.compress / gzip.compress); the plain texts are rebuilt here
// so a bad decoder cannot pass by construction. No network.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class LiveInflateTests: XCTestCase {
    private func data(base64: String) -> Data {
        Data(base64Encoded: base64)!
    }

    private var danmuJSON: Data {
        Data("{\"cmd\":\"DANMU_MSG\",\"info\":[[0,16777215,0,\"#ffffff\"],\"hello live\",[123,\"tester\",0]]}".utf8)
    }

    func testInflateZlibSmall() throws {
        let compressed = data(base64: "eJzLSM3JyVdISczLTcwuVSjPL8pJ0VHIAAvmZJalKhTl5+cqAgAGow2M")
        let plain = try LiveInflate.inflateZlib(compressed)
        XCTAssertEqual(plain, Data("hello danmaku world, hello live room!".utf8))
    }

    func testInflateZlibLargeRepeatedFrames() throws {
        let compressed = data(base64: "eJztzDEKwjAYBtCrlK/rPyQVDWQrFJziIk4hOGhCC6kBDS6hdxd6CofvHeA1PNYnLKbx4m53dz1DsLxSgfVeiT4ZYwZ9FCXo0w5BMMecS5eXb4R4PRwENX5qfENUCFtjyZIlS5YsWbJkyZIly38qf4/KviY=")
        var expected = Data()
        for _ in 0..<40 {
            expected.append(danmuJSON)
        }
        XCTAssertEqual(expected.count, 3320)
        let plain = try LiveInflate.inflateZlib(compressed)
        XCTAssertEqual(plain, expected)
    }

    func testInflateZlibStoredBlock() throws {
        let compressed = data(base64: "eAEBFwDo/3N0b3JlZCBibG9jayB0ZXN0IDEyMzQ1Z4sHvA==")
        let plain = try LiveInflate.inflateZlib(compressed)
        XCTAssertEqual(plain, Data("stored block test 12345".utf8))
    }

    func testInflateGzipChat() throws {
        let compressed = data(base64: "H4sIAPUlBGsC/6tWSs5NUbJScnH08w2N9w12V9JRysxLy1eyio420DE0Mzc3NzI01THQUVJOAwOlWB2l9KrMAoXkjMQShZLU4hIlnWgTUzOQaGlxapGSjkFsbC0A1ayczFcAAAA=")
        let expected = Data("{\"cmd\":\"DANMU_MSG\",\"info\":[[0,16777215,0,\"#ffffff\"],\"gzip chat test\",[456,\"gzuser\",0]]}".utf8)
        XCTAssertEqual(expected.count, 87)
        let plain = try LiveInflate.inflateGzip(compressed)
        XCTAssertEqual(plain, expected)
    }

    func testIsGzipMagic() {
        XCTAssertTrue(LiveInflate.isGzip(Data([0x1F, 0x8B, 0x08, 0x00])))
        XCTAssertFalse(LiveInflate.isGzip(Data([0x78, 0x9C, 0x00])))
        XCTAssertFalse(LiveInflate.isGzip(Data()))
    }

    func testInflateRejectsGarbage() {
        XCTAssertThrowsError(try LiveInflate.inflateZlib(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertThrowsError(try LiveInflate.inflateGzip(Data("not gzip at all".utf8)))
        XCTAssertThrowsError(try LiveInflate.inflate(Data([0xFF, 0xFF, 0xFF])))
    }

    func testInflateZlibRejectsBadAdler() throws {
        // Valid zlib stream whose Adler-32 trailer is zeroed: the
        // decoder must refuse it rather than return unchecked bytes.
        var compressed = [UInt8](data(base64: "eJzLSM3JyVdISczLTcwuVSjPL8pJ0VHIAAvmZJalKhTl5+cqAgAGow2M"))
        compressed[compressed.count - 1] ^= 0xFF
        compressed[compressed.count - 2] ^= 0xFF
        XCTAssertThrowsError(try LiveInflate.inflateZlib(Data(compressed)))
    }
}
