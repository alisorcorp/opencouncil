import XCTest
@testable import CouncilCore

final class FileTailTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try Fixtures.tempDir("tail") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var expectations: [(count: Int, exp: XCTestExpectation)] = []
        func add(_ new: [String]) {
            lock.lock(); lines += new; let n = lines.count
            let ready = expectations.filter { n >= $0.count }
            expectations.removeAll { n >= $0.count }
            lock.unlock()
            ready.forEach { $0.exp.fulfill() }
        }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
        func expect(count: Int, _ exp: XCTestExpectation) {
            lock.lock(); if lines.count >= count { lock.unlock(); exp.fulfill(); return }
            expectations.append((count, exp)); lock.unlock()
        }
    }

    private func append(_ s: String, to url: URL) throws {
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.seekToEnd()
        try fh.write(contentsOf: s.data(using: .utf8)!)
    }

    func testDeliversAppendedLinesAndHoldsPartials() throws {
        let url = dir.appendingPathComponent("log.jsonl")
        try "first\n".write(to: url, atomically: true, encoding: .utf8)
        let c = Collector()
        let tail = FileTail(url: url) { c.add($0.map { String(decoding: $0, as: UTF8.self) }) }
        defer { tail.stop() }
        let e1 = expectation(description: "replay"); c.expect(count: 1, e1)
        tail.start(replayExisting: true)
        wait(for: [e1], timeout: 3)
        XCTAssertEqual(c.all(), ["first"])

        try append("second\nthi", to: url)
        let e2 = expectation(description: "second"); c.expect(count: 2, e2)
        wait(for: [e2], timeout: 3)
        XCTAssertEqual(c.all(), ["first", "second"], "partial line must be held back")

        try append("rd\n\n   \nfourth\n", to: url)
        let e3 = expectation(description: "rest"); c.expect(count: 4, e3)
        wait(for: [e3], timeout: 3)
        XCTAssertEqual(c.all(), ["first", "second", "third", "fourth"], "blank lines skipped, partial completed")
    }

    func testReplayFalseOnlyDeliversNewLines() throws {
        let url = dir.appendingPathComponent("log.jsonl")
        try "old\n".write(to: url, atomically: true, encoding: .utf8)
        let c = Collector()
        let tail = FileTail(url: url) { c.add($0.map { String(decoding: $0, as: UTF8.self) }) }
        defer { tail.stop() }
        tail.start(replayExisting: false)
        Thread.sleep(forTimeInterval: 0.2)
        try append("new\n", to: url)
        let e = expectation(description: "new"); c.expect(count: 1, e)
        wait(for: [e], timeout: 3)
        XCTAssertEqual(c.all(), ["new"])
    }

    func testSurvivesAtomicReplaceAndTruncation() throws {
        let url = dir.appendingPathComponent("log.jsonl")
        try "a\n".write(to: url, atomically: true, encoding: .utf8)
        let c = Collector()
        let tail = FileTail(url: url) { c.add($0.map { String(decoding: $0, as: UTF8.self) }) }
        defer { tail.stop() }
        let e1 = expectation(description: "a"); c.expect(count: 1, e1)
        tail.start()
        wait(for: [e1], timeout: 3)
        // Atomic replace: new inode at the same path.
        try "b\n".write(to: url, atomically: true, encoding: .utf8)
        let e2 = expectation(description: "b"); c.expect(count: 2, e2)
        wait(for: [e2], timeout: 3)
        XCTAssertEqual(c.all(), ["a", "b"])
        // Truncate in place, then append: offset resets.
        try Data().write(to: url)
        Thread.sleep(forTimeInterval: 0.1)
        try append("c\n", to: url)
        let e3 = expectation(description: "c"); c.expect(count: 3, e3)
        wait(for: [e3], timeout: 3)
        XCTAssertEqual(c.all().last, "c")
    }

    func testCreatesMissingFile() throws {
        let url = dir.appendingPathComponent("events.jsonl")
        let c = Collector()
        let tail = FileTail(url: url) { c.add($0.map { String(decoding: $0, as: UTF8.self) }) }
        defer { tail.stop() }
        tail.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try append("x\n", to: url)
        let e = expectation(description: "x"); c.expect(count: 1, e)
        wait(for: [e], timeout: 3)
    }

    func testBusTailDecodesMessages() throws {
        let bus = Bus(directory: dir)
        let box = Collector()
        let tail = BusTail(bus: bus) { msgs in box.add(msgs.map(\.sender)) }
        defer { tail.stop() }
        tail.start()
        Thread.sleep(forTimeInterval: 0.2)
        try bus.append(sender: "user", text: "hi", members: [])
        try bus.append(sender: "codex", text: "yo", members: [])
        let e = expectation(description: "two"); box.expect(count: 2, e)
        wait(for: [e], timeout: 3)
        XCTAssertEqual(box.all(), ["user", "codex"])
    }

    /// kqueue reports nothing about writes that land while the source is being set up. Without a read straight
    /// after it starts, this line would sit unseen until something else was appended.
    func testAWriteDuringStartupIsNotMissed() throws {
        let url = dir.appendingPathComponent("startup.jsonl")
        try "first\n".write(to: url, atomically: true, encoding: .utf8)
        let c = Collector()
        let tail = FileTail(url: url) { c.add($0.map { String(decoding: $0, as: UTF8.self) }) }
        defer { tail.stop() }
        let done = expectation(description: "both lines")
        c.expect(count: 2, done)
        tail.start(replayExisting: true)
        try append("second\n", to: url)          // racing the source's registration on purpose
        wait(for: [done], timeout: 3)
        XCTAssertEqual(c.all(), ["first", "second"])
    }
}
