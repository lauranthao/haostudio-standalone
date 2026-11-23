// HAo Studio 2.0 — DownloadEngine state-machine tests (S3 leg B).
//
// No network: downloads run against local file:// URLs, which the
// engine copies in chunks on a background queue. A fresh engine
// instance per test; unique keys/file names per test so the
// persisted `downloadTasks` index can never cross-contaminate.
// Swift 5.0: no async/await, no `any`.

import XCTest
@testable import AppCore

final class DownloadEngineTests: XCTestCase {
    private var engine: DownloadEngine!
    private var keys: [String] = []
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        engine = DownloadEngine()
        keys = []
        tempFiles = []
    }

    override func tearDown() {
        for key in keys {
            engine.delete(key: key)
        }
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        engine = nil
        super.tearDown()
    }

    private func makeSourceFile(size: Int) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-src-\(UUID().uuidString).bin")
        var data = Data(count: size)
        // Non-zero content so a truncated copy is distinguishable.
        for i in stride(from: 0, to: size, by: 4096) {
            data[i] = UInt8(i & 0xFF)
        }
        try! data.write(to: url)
        tempFiles.append(url)
        return url
    }

    private func request(key: String, source: URL, fileName: String) -> DownloadRequest {
        keys.append(key)
        return DownloadRequest(
            key: key,
            title: "test \(key)",
            sourceURL: source,
            fileName: fileName,
            kind: .music,
            qualityCode: "320k"
        )
    }

    private func downloadsDir() -> URL {
        LocalStore.documentsDirectory().appendingPathComponent(DownloadEngine.downloadSubdir)
    }

    // MARK: - Happy path

    func testFileDownloadCompletesAndLandsAtRelativePath() {
        let key = "t-complete-\(UUID().uuidString)"
        let source = makeSourceFile(size: 256 * 1024)
        let fileName = "test-\(UUID().uuidString).bin"
        let done = expectation(description: "download completes")
        var sawProgress = false
        engine.enqueue(request: request(key: key, source: source, fileName: fileName), progress: { _, _ in
            sawProgress = true
        }) { info in
            XCTAssertEqual(info.state, .completed)
            XCTAssertEqual(info.downloadedBytes, 256 * 1024)
            XCTAssertEqual(info.totalBytes, 256 * 1024)
            XCTAssertEqual(info.localRelativePath, "music_downloads/\(fileName)")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(sawProgress)
        let landed = downloadsDir().appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertEqual((try? Data(contentsOf: landed))?.count, 256 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: landed.appendingPathExtension("part").path))
    }

    // MARK: - Duplicate key

    func testDuplicateEnqueueReturnsExistingTask() {
        let key = "t-dup-\(UUID().uuidString)"
        let source = makeSourceFile(size: 8 * 1024 * 1024)
        engine.testChunkDelay = 0.05
        let done = expectation(description: "download completes")
        let first = engine.enqueue(request: request(key: key, source: source, fileName: "dup.bin")) { _ in
            done.fulfill()
        }
        XCTAssertEqual(first.state, .queued)
        let second = engine.enqueue(request: request(key: key, source: source, fileName: "dup.bin"))
        XCTAssertEqual(second.key, key)
        XCTAssertEqual(engine.allTasks().filter { $0.request.key == key }.count, 1)
        wait(for: [done], timeout: 20)
    }

    // MARK: - Pause / resume

    func testPauseThenResumeCompletes() {
        let key = "t-pause-\(UUID().uuidString)"
        let source = makeSourceFile(size: 8 * 1024 * 1024)
        let fileName = "pause-\(UUID().uuidString).bin"
        engine.testChunkDelay = 0.05
        let progressSeen = expectation(description: "first progress then pause")
        var didPause = false
        engine.enqueue(request: request(key: key, source: source, fileName: fileName), progress: { [weak self] downloaded, _ in
            guard let self = self, !didPause, downloaded > 0 else { return }
            didPause = true
            self.engine.pause(key: key)
            progressSeen.fulfill()
        }, completion: nil)
        wait(for: [progressSeen], timeout: 10)

        // Paused mid-file: part file exists, partial, no final file.
        let info = engine.taskInfo(for: key)
        XCTAssertEqual(info?.state, .paused)
        let part = downloadsDir().appendingPathComponent(fileName).appendingPathExtension("part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        let partSize = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(partSize, 0)
        XCTAssertLessThan(partSize, 8 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir().appendingPathComponent(fileName).path))

        // Resume from the part file and finish.
        engine.resume(key: key)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if engine.taskInfo(for: key)?.state == .completed { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(engine.taskInfo(for: key)?.state, .completed)
        XCTAssertEqual(engine.taskInfo(for: key)?.downloadedBytes, 8 * 1024 * 1024)
    }

    // MARK: - Cancel

    func testCancelDeletesPartFile() {
        let key = "t-cancel-\(UUID().uuidString)"
        let source = makeSourceFile(size: 8 * 1024 * 1024)
        let fileName = "cancel-\(UUID().uuidString).bin"
        engine.testChunkDelay = 0.05
        let cancelled = expectation(description: "cancel completes")
        var didCancel = false
        engine.enqueue(request: request(key: key, source: source, fileName: fileName), progress: { [weak self] downloaded, _ in
            guard let self = self, !didCancel, downloaded > 0 else { return }
            didCancel = true
            self.engine.cancel(key: key)
        }) { info in
            XCTAssertEqual(info.state, .cancelled)
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 10)
        let part = downloadsDir().appendingPathComponent(fileName).appendingPathExtension("part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir().appendingPathComponent(fileName).path))
    }

    // MARK: - Failure

    func testUnsupportedSchemeFails() {
        let key = "t-badscheme-\(UUID().uuidString)"
        let failed = expectation(description: "unsupported scheme fails")
        engine.enqueue(request: DownloadRequest(
            key: key,
            title: "bad",
            sourceURL: URL(string: "ftp://example.com/x.mp3")!,
            fileName: "bad.mp3",
            kind: .music,
            qualityCode: "320k"
        )) { info in
            XCTAssertEqual(info.state, .failed)
            XCTAssertNotNil(info.errorMessage)
            failed.fulfill()
        }
        keys.append(key)
        wait(for: [failed], timeout: 10)
    }

    func testMissingLocalFileFails() {
        let key = "t-missing-\(UUID().uuidString)"
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).bin")
        let failed = expectation(description: "missing file fails")
        engine.enqueue(request: request(key: key, source: missing, fileName: "missing.bin")) { info in
            XCTAssertEqual(info.state, .failed)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 10)
    }

    // MARK: - File-name sanitising

    func testSanitisedFileName() {
        XCTAssertEqual(DownloadEngine.sanitisedFileName("a/b\\c:d.mp3", fallbackKey: "k"), "a_b_c_d.mp3")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("../evil.mp3", fallbackKey: "k"), "evil.mp3")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("", fallbackKey: "k"), "k.bin")
        XCTAssertEqual(DownloadEngine.sanitisedFileName("  song.mp3  ", fallbackKey: "k"), "song.mp3")
    }
}
