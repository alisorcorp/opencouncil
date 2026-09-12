import XCTest
@testable import CouncilCore

/// R19: quitting the app must not lose a conversation. A delivery that was in flight when the app stopped is
/// sent again rather than forgotten. (The resume launch arguments themselves are covered by `LaunchPlanTests`.)
final class ResumeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    // MARK: the ledger carries enough to send a delivery again

    func testAnInterruptedDeliveryKeepsItsTextAndComesBackAsInterrupted() throws {
        let dir = try Fixtures.tempDir("resume-ledger")
        defer { try? FileManager.default.removeItem(at: dir) }
        var supervisor = MemberSupervisor(members: ["claude"])
        supervisor.launched("claude", now: t0)
        _ = supervisor.apply(.started(sessionId: "s1", reason: nil), to: "claude", now: t0)

        let ledger = DeliveryLedger(directory: dir)
        for effect in supervisor.send("[user] what about the router?", to: "claude", upTo: 12, now: t0) {
            if case .open(let d) = effect { try ledger.open(d) }
        }
        // …and the process dies here, before any outcome is written.

        let reopened = DeliveryLedger(directory: dir)
        let orphans = try reopened.closeOrphans(at: MessageTime.format(t0.addingTimeInterval(60)))
        XCTAssertEqual(orphans.count, 1)
        let orphan = try XCTUnwrap(orphans.first)
        XCTAssertEqual(orphan.member, "claude")
        XCTAssertEqual(orphan.text, "[user] what about the router?", "the text is what makes a re-send possible")
        XCTAssertEqual(orphan.upToMessageId, 12)
        XCTAssertEqual(reopened.all().first?.outcome, .interrupted)
    }

    func testTheSecondSendSaysWhyItIsBeingAskedAgain() {
        let again = Briefing.interruptedNote + "[user] what about the router?"
        XCTAssertTrue(again.hasPrefix("The app restarted while you were answering this."))
        XCTAssertTrue(again.hasSuffix("[user] what about the router?"), "the original delivery is unchanged")
    }

    func testALedgerWrittenBeforeDeliveryTextWasStoredStillLoads() throws {
        let dir = try Fixtures.tempDir("resume-old-ledger")
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = #"{"attempts":1,"id":"old","member":"codex","opened":"2026-09-10T22:00:00","upToMessageId":3}"#
        try (line + "\n").write(to: dir.appendingPathComponent(DeliveryLedger.fileName), atomically: true, encoding: .utf8)
        let ledger = DeliveryLedger(directory: dir)
        XCTAssertEqual(ledger.all().count, 1)
        XCTAssertNil(ledger.all().first?.text, "nothing to re-send, but the record still reads")
        XCTAssertEqual(try ledger.closeOrphans(at: "t").count, 1)
    }
}
