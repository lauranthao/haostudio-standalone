// HAo Studio 2.0 — Emby image loader tests (S5, leg A).
//
// iOS-only (see SettingsStoreTests.swift header): unwired in
// `ios/Package.swift`, runs under the S7 Xcode test target.
// No network: the URLSession is built on a stub URLProtocol
// that answers from canned statuses / data, and the config is
// passed explicitly so the loader never reads the stored config
// (no Documents / Keychain touch).

import Foundation
import UIKit
import XCTest

@testable import AppCore

/// URLProtocol stub: answers every request from `handler` and
/// counts requests, so the cache behaviour is observable.
final class StubImageURLProtocol: URLProtocol {
    /// (status, body) for a request.
    static var handler: ((URLRequest) -> (Int, Data?))?
    static var requestCount = 0
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubImageURLProtocol.requestCount += 1
        StubImageURLProtocol.lastRequest = request
        let (status, data) = StubImageURLProtocol.handler?(request) ?? (404, nil)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ImageLoaderTests: XCTestCase {
    private var session: URLSession!
    private var loader: EmbyImageLoader!
    private let configured = EmbyServerConfig(baseUrl: "http://emby.local:8096", apiKey: "key-123")
    private let imageURL = "http://emby.local:8096/emby/Items/abc/Images/Primary?maxWidth=400"

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubImageURLProtocol.self]
        session = URLSession(configuration: config)
        loader = EmbyImageLoader()
        StubImageURLProtocol.requestCount = 0
        StubImageURLProtocol.lastRequest = nil
        StubImageURLProtocol.handler = nil
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubImageURLProtocol.handler = nil
        super.tearDown()
    }

    private func load(
        urlString: String? = nil,
        config: EmbyServerConfig? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) -> UIImage?? {
        var result: UIImage??
        let expectation = self.expectation(description: "image load completes")
        loader.load(urlString: urlString ?? imageURL, config: config ?? configured, session: session) { image in
            result = image
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
        return result
    }

    func testInvalidURLReturnsNilWithoutNetwork() {
        let image = load(urlString: "not a url :::")
        XCTAssertNil(image ?? nil)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 0)
    }

    func testUnconfiguredServerReturnsNilWithoutNetwork() {
        let unconfigured = EmbyServerConfig(baseUrl: "http://emby.local:8096")
        XCTAssertFalse(unconfigured.isConfigured)
        let image = load(config: unconfigured)
        XCTAssertNil(image ?? nil)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 0)
    }

    func testSuccessCachesAndSendsAuthHeader() {
        let data = SettingsTestImages.pngData()
        var sawToken: String?
        var sawURL: String?
        StubImageURLProtocol.handler = { request in
            sawToken = request.value(forHTTPHeaderField: "X-Emby-Token")
            sawURL = request.url?.absoluteString
            return (200, data)
        }
        let first = load()
        XCTAssertNotNil(first ?? nil)
        XCTAssertEqual(sawToken, "key-123")
        // The token never enters the URL.
        XCTAssertEqual(sawURL?.contains("key-123"), false)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 1)
        // Second load is served from the memory cache: no request.
        let second = load()
        XCTAssertNotNil(second ?? nil)
        XCTAssertEqual(StubImageURLProtocol.requestCount, 1)
    }

    func testUnauthorizedReturnsNilAndDoesNotCache() {
        StubImageURLProtocol.handler = { _ in (401, nil) }
        let first = load()
        XCTAssertNil(first ?? nil)
        let second = load()
        XCTAssertNil(second ?? nil)
        // No retry loop, and no poisoned cache entry: both loads
        // hit the network.
        XCTAssertEqual(StubImageURLProtocol.requestCount, 2)
    }

    func testBadImageDataReturnsNil() {
        StubImageURLProtocol.handler = { _ in (200, Data("not an image".utf8)) }
        let image = load()
        XCTAssertNil(image ?? nil)
    }
}
