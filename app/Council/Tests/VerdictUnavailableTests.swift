import XCTest
import CouncilCore
@testable import Council

/// A verdict round waits for exactly the members it asked. When one becomes unavailable, the round has to
/// decide whether to stop waiting on it or hold — and the answer turns on *why* it went away, not on the mere
/// fact that it did. A clean exit is the case that regressed: `MemberSupervisor.exited(status: 0)` records
/// `.notRunning`, so a translation that only failed a member in `.error` left the round waiting the full
/// half-hour answer timeout for a member the user had already quit in its (now reachable) terminal.
final class VerdictUnavailableTests: XCTestCase {
    func testACleanExitFailsTheRound() {
        // The regression: no reason string of its own, but the member is gone, so the round must not wait.
        XCTAssertEqual(VerdictRuntime.failureReason(forUnavailable: .notRunning), "stopped without answering")
    }

    func testAnErrorKeepsItsOwnReason() {
        XCTAssertEqual(VerdictRuntime.failureReason(forUnavailable: .error(reason: "exited with status 1")),
                       "exited with status 1")
    }

    func testADialogKeepsTheRoundWaiting() {
        // Blocked is recoverable: the user clears the dialog and `.unblocked` puts the member back to work.
        XCTAssertNil(VerdictRuntime.failureReason(forUnavailable: .blocked(reason: "needs permission")))
        XCTAssertNil(VerdictRuntime.failureReason(forUnavailable: .blockedBeforeStart(reason: "trust dialog")))
    }
}
