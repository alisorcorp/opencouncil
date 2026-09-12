import XCTest
@testable import CouncilCore

/// R14: every routed message ends in a reply, a "nothing to add" note or a card. The ledger is what makes that
/// checkable after the fact — and what turns a delivery the app never finished into an honest "interrupted".
final class DeliveryLedgerTests: XCTestCase {
    private func ledger() throws -> (DeliveryLedger, URL) {
        let dir = try Fixtures.tempDir("ledger")
        return (DeliveryLedger(directory: dir), dir)
    }

    func testADeliveryIsOpenUntilItIsClosed() throws {
        let (ledger, dir) = try ledger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Delivery(id: "d1", member: "claude", opened: "2026-09-11T00:00:00", upToMessageId: 7)
        try ledger.open(d)
        XCTAssertEqual(ledger.all().count, 1)
        XCTAssertEqual(ledger.open().map(\.id), ["d1"])
        try ledger.close(id: "d1", outcome: .posted, postId: 9, at: "2026-09-11T00:00:04")
        XCTAssertTrue(ledger.open().isEmpty)
        let closed = try XCTUnwrap(ledger.all().first)
        XCTAssertEqual(closed.outcome, .posted)
        XCTAssertEqual(closed.postId, 9)
        XCTAssertEqual(closed.closed, "2026-09-11T00:00:04")
        XCTAssertEqual(closed.upToMessageId, 7, "closing keeps what the delivery carried")
    }

    func testTheFileIsAppendOnlyAndFoldsToTheLastStateOfEachDelivery() throws {
        let (ledger, dir) = try ledger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ledger.open(Delivery(id: "d1", member: "claude", opened: "t0", upToMessageId: 1))
        try ledger.open(Delivery(id: "d2", member: "codex", opened: "t0", upToMessageId: 1))
        try ledger.close(id: "d1", outcome: .nothingToAdd, postId: nil, at: "t1")
        let lines = try String(contentsOf: dir.appendingPathComponent(DeliveryLedger.fileName), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "nothing is rewritten in place")
        XCTAssertEqual(ledger.all().map(\.id), ["d1", "d2"], "folded in the order the deliveries opened")
        XCTAssertEqual(ledger.all()[0].outcome, .nothingToAdd)
        XCTAssertNil(ledger.all()[1].outcome)
    }

    func testDeliveriesLeftOpenByACrashComeBackAsInterrupted() throws {
        let (ledger, dir) = try ledger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ledger.open(Delivery(id: "d1", member: "claude", opened: "t0", upToMessageId: 1))
        try ledger.open(Delivery(id: "d2", member: "codex", opened: "t0", upToMessageId: 1))
        try ledger.close(id: "d2", outcome: .posted, postId: 4, at: "t1")

        // A new process opens the same chat: whatever was still open did not survive the last one.
        let reopened = DeliveryLedger(directory: dir)
        let orphans = try reopened.closeOrphans(at: "t2")
        XCTAssertEqual(orphans.map(\.id), ["d1"])
        XCTAssertTrue(reopened.open().isEmpty)
        XCTAssertEqual(reopened.all().first?.outcome, .interrupted)
        XCTAssertTrue(try reopened.closeOrphans(at: "t3").isEmpty, "a second pass has nothing left to do")
    }

    func testAMissingFileIsAnEmptyLedgerRatherThanAnError() throws {
        let (ledger, dir) = try ledger()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ledger.all().isEmpty)
        XCTAssertTrue(ledger.open().isEmpty)
    }

    func testOutcomesForOneMemberCanBeCounted() throws {
        let (ledger, dir) = try ledger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ledger.open(Delivery(id: "a", member: "claude", opened: "t0", upToMessageId: 1))
        try ledger.close(id: "a", outcome: .posted, postId: 2, at: "t1")
        try ledger.open(Delivery(id: "b", member: "claude", opened: "t2", upToMessageId: 3))
        try ledger.close(id: "b", outcome: .nothingToAdd, postId: nil, at: "t3")
        try ledger.open(Delivery(id: "c", member: "codex", opened: "t2", upToMessageId: 3))
        XCTAssertEqual(ledger.all(for: "claude").count, 2)
        XCTAssertEqual(ledger.all(for: "codex").map(\.outcome), [nil])
    }
}
