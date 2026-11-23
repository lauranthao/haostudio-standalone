// HAo Studio 2.0 — Live features smoke tests (S4 leg B).
//
// Only asserts that every platform resolves to its site
// implementation through the shared factory. C leg adds
// LiveLibraryStore tests here (settings / favourites / history).
// No network. Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class LiveFeaturesSmokeTests: XCTestCase {
    private var notFoundFetcher: LiveDataFetcher {
        { _, completion in completion(nil, 404, nil) }
    }

    func testAllFivePlatformsHaveResolvers() {
        let cases: [(LivePlatform, Any.Type)] = [
            (.bilibili, BilibiliLiveSite.self),
            (.douyu, DouyuLiveSite.self),
            (.huya, HuyaLiveSite.self),
            (.douyin, DouyinLiveSite.self),
            (.kuaishou, KuaishouLiveSite.self)
        ]
        for (platform, expectedType) in cases {
            let resolver = LiveSites.resolver(for: platform, fetcher: notFoundFetcher)
            XCTAssertTrue(type(of: resolver) == expectedType, "\(platform) resolved to \(type(of: resolver))")
            XCTAssertEqual(resolver.platform, platform)
        }
    }

    func testResolverRejectsEmptyRoomId() {
        for platform in LivePlatform.allCases {
            let resolver = LiveSites.resolver(for: platform, fetcher: notFoundFetcher)
            let roomExpectation = expectation(description: "roomInfo \(platform)")
            resolver.roomInfo(roomId: "   ") { result in
                if case .failure(let error as LiveError) = result {
                    if case .invalidRoomId = error {
                        // Expected.
                    } else {
                        XCTFail("expected invalidRoomId, got \(error)")
                    }
                } else {
                    XCTFail("expected failure, got \(result)")
                }
                roomExpectation.fulfill()
            }
            let resolveExpectation = expectation(description: "resolve \(platform)")
            resolver.resolve(roomId: "", quality: nil) { result in
                if case .failure(let error as LiveError) = result {
                    if case .invalidRoomId = error {
                        // Expected.
                    } else {
                        XCTFail("expected invalidRoomId, got \(error)")
                    }
                } else {
                    XCTFail("expected failure, got \(result)")
                }
                resolveExpectation.fulfill()
            }
        }
        waitForExpectations(timeout: 5)
    }
}
