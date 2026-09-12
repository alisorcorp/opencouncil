import XCTest
@testable import CouncilCore

/// Two routers on one chat would paste into the same terminals twice. The lock is the only thing stopping the
/// app and the CLI from doing that, so its failure modes matter more than its happy path.
final class RouterLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try Fixtures.tempDir("router-lock") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAcquireWritesTheHolderAndReleaseRemovesIt() throws {
        let lock = RouterLock(directory: dir)
        let holder = try lock.acquire()
        XCTAssertEqual(holder.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(holder.owner, "app")
        XCTAssertEqual(lock.holder(), holder)
        lock.release()
        XCTAssertNil(lock.holder())
    }

    func testTheSameProcessCanReacquireItsOwnLock() throws {
        let lock = RouterLock(directory: dir)
        try lock.acquire()
        XCTAssertNoThrow(try lock.acquire())
    }

    func testALockHeldByALiveProcessIsRefused() throws {
        try write(RouterLock.Holder(pid: 1, host: RouterLock.hostName, owner: "cli", since: "2026-09-10T22:00:00"))
        XCTAssertThrowsError(try RouterLock(directory: dir).acquire()) { error in
            guard case RouterLock.LockError.held(let h) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(h.owner, "cli")
            XCTAssertTrue(error.localizedDescription.contains("council CLI"), error.localizedDescription)
        }
    }

    func testAStaleLockIsTakenOver() throws {
        try write(RouterLock.Holder(pid: deadPID(), host: RouterLock.hostName, owner: "cli", since: "2026-09-10T22:00:00"))
        let holder = try RouterLock(directory: dir).acquire()
        XCTAssertEqual(holder.pid, ProcessInfo.processInfo.processIdentifier)
    }

    func testALiveLockCanBeTakenOverOnlyOnPurpose() throws {
        try write(RouterLock.Holder(pid: 1, host: RouterLock.hostName, owner: "cli", since: "2026-09-10T22:00:00"))
        let lock = RouterLock(directory: dir)
        XCTAssertThrowsError(try lock.acquire())
        XCTAssertNoThrow(try lock.acquire(force: true))
    }

    func testALockFromAnotherMachineIsNotTakenOver() throws {
        try write(RouterLock.Holder(pid: 999_999, host: "someone-elses-mac", owner: "app", since: "2026-09-10T22:00:00"))
        XCTAssertThrowsError(try RouterLock(directory: dir).acquire())
    }

    func testReleaseLeavesSomeoneElsesLockAlone() throws {
        let theirs = RouterLock.Holder(pid: 1, host: RouterLock.hostName, owner: "cli", since: "2026-09-10T22:00:00")
        try write(theirs)
        RouterLock(directory: dir).release()
        XCTAssertEqual(RouterLock(directory: dir).holder(), theirs)
    }

    func testAnUnreadableLockFileIsTreatedAsNoLock() throws {
        try "not json".write(to: dir.appendingPathComponent("router.lock"), atomically: true, encoding: .utf8)
        XCTAssertNil(RouterLock(directory: dir).holder())
        XCTAssertNoThrow(try RouterLock(directory: dir).acquire())
    }

    /// The CLI writes the same file; the app has to read what Python wrote.
    func testThePythonLockShapeIsUnderstood() throws {
        let json = #"{"host": "\#(RouterLock.hostName)", "owner": "cli", "pid": 1, "since": "2026-09-10T22:00:00"}"#
        try json.write(to: dir.appendingPathComponent("router.lock"), atomically: true, encoding: .utf8)
        let holder = RouterLock(directory: dir).holder()
        XCTAssertEqual(holder?.owner, "cli")
        XCTAssertEqual(holder?.pid, 1)
    }

    /// The CLI and the app have to refuse each other's locks, not just parse them. This drives the real
    /// chat.py helpers against the real Swift lock in one directory.
    func testTheCLIAndTheAppRefuseEachOthersLocks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("chat.py").path) else {
            throw XCTSkip("chat.py not found")
        }
        // The app holds the chat: the CLI must refuse it.
        try RouterLock(directory: dir).acquire()
        let refused = try python(root, "chat.acquire_router_lock(pathlib.Path(sys.argv[1]))")
        XCTAssertNotEqual(refused.status, 0, "the CLI took a lock the app was holding")
        XCTAssertTrue(refused.err.contains("Open Council"), refused.err)

        // The app releases, the CLI takes it, and now the app must refuse.
        RouterLock(directory: dir).release()
        let taken = try python(root, "chat.acquire_router_lock(pathlib.Path(sys.argv[1]))")
        XCTAssertEqual(taken.status, 0, taken.err)
        XCTAssertEqual(RouterLock(directory: dir).holder()?.owner, "cli")
    }

    private func python(_ root: URL, _ code: String) throws -> (status: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import sys, pathlib; sys.path.insert(0, sys.argv[2]); import chat; \(code)",
                       dir.path, root.path]
        p.currentDirectoryURL = root
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }

    private func write(_ holder: RouterLock.Holder) throws {
        try JSONEncoder().encode(holder).write(to: dir.appendingPathComponent("router.lock"))
    }

    /// A pid that is certainly not running: fork a process, wait for it, reuse its id.
    private func deadPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }
}
